import Foundation

/// Every swappable model in the pipeline is an "engine." Engines declare an identifier (for the
/// model-decision-record) and a lifecycle so the orchestrator can enforce the single-AI-model-
/// resident rule — ASR fully unloaded before the LLM loads (PRD §9.6).
public protocol Engine: Sendable {
    /// Stable id used in metrics and the ModelAsset table, e.g. "whisperkit-small.en@1.0".
    var identifier: String { get }
    /// Load weights into memory. Called immediately before first use.
    func load() async throws
    /// Release weights. The orchestrator awaits this before loading the next large model.
    func unload() async
    /// Best-effort resident-set estimate in bytes while loaded (for the budget report).
    var approxResidentBytes: Int { get }
}

public extension Engine {
    func load() async throws {}
    func unload() async {}
    var approxResidentBytes: Int { 0 }
}

// MARK: - ASR

/// Speech-to-text. Candidates in the P0 bake-off: SpeechTranscriber (default), WhisperKit small.en,
/// WhisperKit base.en (PRD §9.3). The playhead-anchored streaming variant is what powers the
/// first-play degraded state (PRD §8.1) — implementers transcribe *ahead of the playhead first*.
public protocol SpeechToTextEngine: Engine {
    /// Batch transcription of a whole file (bake-off path).
    func transcribe(audioURL: URL) async throws -> Transcript

    /// Streaming transcription anchored at `fromMs`, yielding segments as they finalize.
    /// Default implementation falls back to a batch transcribe (override for true streaming).
    func transcribeStream(audioURL: URL, fromMs: Int) -> AsyncThrowingStream<TranscriptSegment, Error>
}

public extension SpeechToTextEngine {
    func transcribeStream(audioURL: URL, fromMs: Int) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let t = try await transcribe(audioURL: audioURL)
                    for seg in t.segments where seg.startMs >= fromMs {
                        continuation.yield(seg)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Diarization

/// Assigns speaker clusters aligned to transcript segments. Candidates: FluidAudio (Apache-2.0),
/// SpeakerKit (MIT). Runs on the official-transcript path too, since SRT/VTT lack speakers (§9.3).
public protocol DiarizationEngine: Engine {
    /// Returns the transcript with `speaker` populated (anonymized cluster ids like "SPEAKER_0").
    func diarize(audioURL: URL, transcript: Transcript) async throws -> Transcript
}

// MARK: - Embeddings

/// Per-segment embeddings for find-a-moment. Candidates: NLContextualEmbedding vs a bundled
/// MiniLM/bge-small-class model (§9.3). Runs incrementally, in parallel with LLM passes (§9.5).
public protocol EmbeddingEngine: Engine {
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

// MARK: - The LLM (the intelligence layer)

/// The pluggable intelligence engine (PRD §9.3). Tier 1 = Apple Foundation Models; Tier 2 = a
/// bundled ~2B 4-bit model on the ANE via Core ML. The API is shaped around chunked map-reduce so
/// it runs identically on Foundation Models' ~4,096-token context.
public protocol EpisodeIntelligenceEngine: Engine {
    /// Model context budget in tokens — the chunker sizes windows to fit this (minus prompt overhead).
    var contextTokenLimit: Int { get }

    /// MAP: analyze one window. Also proposes candidate ad ranges.
    func mapWindow(_ window: TranscriptWindow) async throws -> WindowNotes

    /// REDUCE: fold all window notes into an episode digest. `adFreeText` is the transcript with
    /// detected ads already removed — the ad-exclusion contract is enforced by the orchestrator,
    /// but passed here explicitly so the engine never summarizes a sponsor read (PRD §9.5).
    func reduce(notes: [WindowNotes], adFreeText: String) async throws -> EpisodeDigest

    /// On-demand snip enrichment (queue-jumped).
    func enrichSnip(_ request: SnipEnrichmentRequest) async throws -> SnipEnrichment

    /// Name anonymized speaker clusters ("SPEAKER_0" → "Host") from the episode intro.
    func nameSpeakers(introText: String, clusters: [String]) async throws -> [String: String]
}

// MARK: - Ad detection

/// Ad detection is LLM classification + heuristics (sponsor phrases, promo codes/URLs) (§9.3). Split
/// from EpisodeIntelligence so a tiny fine-tuned classifier can be swapped in independently (v1 Q2).
///
/// **Segment-granular by contract (fixes E7):** returns tight AdRanges around the actual sponsor
/// segments, never whole map windows. It runs BEFORE the LLM map so ad text is removed before the
/// model summarizes — a window that merely *contains* an ad must not lose its real content.
public protocol AdDetectionEngine: Engine {
    func detectAds(in transcript: Transcript) async throws -> [AdRange]
}
