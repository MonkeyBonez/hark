import Foundation

/// Deterministic mock engines. Their ONLY job is to let the whole pipeline + harness compile and
/// run green before any real model is wired in — they prove the *architecture*, not the models.
/// Real adapters (WhisperKit, Foundation Models, Core ML/ANE, FluidAudio, NLContextualEmbedding)
/// implement the same protocols and drop in without touching the orchestrator. Deterministic (no
/// randomness) so tests are stable.

public struct MockSpeechToText: SpeechToTextEngine {
    public let identifier: String
    public let approxResidentBytes: Int
    /// Words-per-minute the fake transcript is generated at; also scales the fake elapsed time.
    private let wordsPerMinute: Int
    private let audioSecondsHint: Double

    public init(identifier: String = "mock-asr", approxResidentBytes: Int = 480 * 1_000_000,
                wordsPerMinute: Int = 150, audioSecondsHint: Double = 3600) {
        self.identifier = identifier; self.approxResidentBytes = approxResidentBytes
        self.wordsPerMinute = wordsPerMinute; self.audioSecondsHint = audioSecondsHint
    }

    public func transcribe(audioURL: URL) async throws -> Transcript {
        // Build a plausible segmented transcript with a fake sponsor read planted mid-episode.
        let totalWords = Int(audioSecondsHint / 60.0 * Double(wordsPerMinute))
        var segments: [TranscriptSegment] = []
        let wordsPerSeg = 12
        let msPerWord = 60_000 / max(1, wordsPerMinute)
        var t = 0
        var wordIdx = 0
        while wordIdx < totalWords {
            let n = min(wordsPerSeg, totalWords - wordIdx)
            // Planted read spans ~16 segments (~77s at 150wpm) — minute-plus so it exercises the
            // chapter-insertion path (ChapterAssembly ignores sub-minute ads by policy).
            let isAd = (wordIdx > totalWords / 3) && (wordIdx < totalWords / 3 + wordsPerSeg * 16)
            let text = isAd
                ? "This episode is sponsored by Acme use promo code SAVE at acme dot com slash deal"
                : "and so the point I was really trying to make here about the topic is worth remembering"
            let start = t
            t += n * msPerWord
            segments.append(TranscriptSegment(text: text, startMs: start, endMs: t))
            wordIdx += n
        }
        return Transcript(episodeId: "mock", source: .asr, format: "asr",
                          modelVersion: identifier, segments: segments)
    }
}

public struct MockDiarizer: DiarizationEngine {
    public let identifier: String
    public let approxResidentBytes: Int
    public init(identifier: String = "mock-diarizer", approxResidentBytes: Int = 90 * 1_000_000) {
        self.identifier = identifier; self.approxResidentBytes = approxResidentBytes
    }
    public func diarize(audioURL: URL, transcript: Transcript) async throws -> Transcript {
        var t = transcript
        t.segments = transcript.segments.enumerated().map { i, seg in
            var s = seg; s.speaker = i % 4 == 0 ? "SPEAKER_1" : "SPEAKER_0"; return s
        }
        return t
    }
}

public struct MockEmbedder: EmbeddingEngine {
    public let identifier: String
    public let approxResidentBytes: Int
    public let dimension: Int
    public init(identifier: String = "mock-embedder", dimension: Int = 384, approxResidentBytes: Int = 120 * 1_000_000) {
        self.identifier = identifier; self.dimension = dimension; self.approxResidentBytes = approxResidentBytes
    }
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        // Deterministic hashed bag-of-words vector — enough for the harness to exercise storage/search.
        texts.map { text in
            var v = [Float](repeating: 0, count: dimension)
            for word in Scoring.normalizeWords(text) {
                let h = abs(word.hashValue) % dimension
                v[h] += 1
            }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? v.map { $0 / norm } : v
        }
    }
}

public struct MockIntelligence: EpisodeIntelligenceEngine {
    public let identifier: String
    public let contextTokenLimit: Int
    public let approxResidentBytes: Int
    public init(identifier: String = "mock-llm", contextTokenLimit: Int = 4096, approxResidentBytes: Int = 1_200 * 1_000_000) {
        self.identifier = identifier; self.contextTokenLimit = contextTokenLimit; self.approxResidentBytes = approxResidentBytes
    }

    public func mapWindow(_ window: TranscriptWindow) async throws -> WindowNotes {
        WindowNotes(windowId: window.id, startMs: window.startMs, endMs: window.endMs,
                    topicLabel: "Window \(window.id)",
                    salientPoints: ["Point from window \(window.id)"],
                    quotableLines: [String(window.text.prefix(60))])
    }

    public func reduce(notes: [WindowNotes], adFreeText: String) async throws -> EpisodeDigest {
        let summary = EpisodeSummary(tldr: "Episode covered \(notes.count) topic windows.",
                                     takeaways: notes.prefix(3).map { "Takeaway: \($0.topicLabel)" })
        let chapters = notes.enumerated().map { i, n in
            Chapter(title: n.topicLabel, startMs: i * 60_000, endMs: (i + 1) * 60_000)
        }
        let keyMoments = notes.prefix(5).map { KeyMoment(title: "Moment: \($0.topicLabel)", startMs: $0.windowId * 60_000, endMs: $0.windowId * 60_000 + 30_000) }
        return EpisodeDigest(summary: summary, keyMoments: Array(keyMoments), chapters: chapters)
    }

    public func enrichSnip(_ request: SnipEnrichmentRequest) async throws -> SnipEnrichment {
        SnipEnrichment(category: .insight, title: "Snip: \(request.excerpt.prefix(24))",
                       bullets: ["Bullet one", "Bullet two"], cleanedExcerpt: request.excerpt)
    }

    public func nameSpeakers(introText: String, clusters: [String]) async throws -> [String: String] {
        var map: [String: String] = [:]
        for (i, c) in clusters.enumerated() { map[c] = i == 0 ? "Host" : "Guest" }
        return map
    }
}

/// Heuristic ad detector: merges LLM window hints and grows confidence with sponsor keywords.
/// Standalone engine so a fine-tuned classifier can replace it independently (v1 open Q2).
public struct MockAdDetector: AdDetectionEngine {
    public let identifier: String
    public let approxResidentBytes: Int
    public init(identifier: String = "mock-ad-detector", approxResidentBytes: Int = 0) {
        self.identifier = identifier; self.approxResidentBytes = approxResidentBytes
    }
    public func detectAds(in transcript: Transcript) async throws -> [AdRange] {
        // Segment-level heuristic: flag individual segments with sponsor-read markers (tight ranges).
        var ranges: [AdRange] = []
        for seg in transcript.segments {
            let t = seg.text.lowercased()
            if t.contains("promo code") || t.contains("dot com slash") || t.contains("sponsored by")
                || t.contains("brought to you by") || t.contains("use code") {
                ranges.append(AdRange(startMs: seg.startMs, endMs: seg.endMs, confidence: 0.7))
            }
        }
        return mergeAdjacent(ranges)
    }

    private func mergeAdjacent(_ ranges: [AdRange]) -> [AdRange] {
        let sorted = ranges.sorted { $0.startMs < $1.startMs }
        var out: [AdRange] = []
        for r in sorted {
            if var last = out.last, r.startMs <= last.endMs + 2000 {
                last.endMs = max(last.endMs, r.endMs)
                last.confidence = max(last.confidence, r.confidence)
                out[out.count - 1] = last
            } else {
                out.append(r)
            }
        }
        return out
    }
}

public extension EngineSet {
    /// A fully-mock engine set so `hark-bench` runs end-to-end with zero models.
    static func mock(label: String = "mock", audioSeconds: Double = 3600) -> EngineSet {
        EngineSet(label: label,
                  asr: MockSpeechToText(audioSecondsHint: audioSeconds),
                  diarizer: MockDiarizer(),
                  embedder: MockEmbedder(),
                  intelligence: MockIntelligence(),
                  adDetector: MockAdDetector())
    }
}
