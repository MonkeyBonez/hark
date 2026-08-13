import Foundation
import WhisperKit

/// ASR adapter for **WhisperKit** (Argmax, Core ML) — the comparison candidate in the PRD §9.3
/// ASR bake-off, run against **SpeechTranscriberASR** on the same eval corpus. Downloads the
/// requested model variant from `argmaxinc/whisperkit-coreml` on first use (cached after).
///
/// **An actor, not a struct** — the `Engine.load()/unload()` lifecycle (single-model-resident rule,
/// PRD §9.6) requires holding the loaded `WhisperKit` pipeline as mutable state between calls. Doing
/// model construction inline inside `transcribe()` (the first version of this adapter) folded
/// download+Core-ML-compile time into the RTF measurement, making a real model look ~2000x slower
/// than it is; moving load into `load()` is what makes the RTF number honest.
public actor WhisperKitASR: SpeechToTextEngine {
    public let identifier: String
    public let approxResidentBytes: Int
    /// e.g. "small.en" or "base.en" (PRD §9.3 candidates).
    public let modelVariant: String
    private var pipe: WhisperKit?

    public init(modelVariant: String = "small.en", approxResidentBytes: Int = 550 * 1_000_000) {
        self.modelVariant = modelVariant
        self.identifier = "whisperkit-\(modelVariant)"
        self.approxResidentBytes = approxResidentBytes
    }

    public func load() async throws {
        guard pipe == nil else { return }
        pipe = try await WhisperKit(WhisperKitConfig(model: modelVariant))
    }

    public func unload() async {
        pipe = nil
    }

    public func transcribe(audioURL: URL) async throws -> Transcript {
        if pipe == nil { try await load() }
        guard let pipe else { throw EngineError.notLoaded }

        // Strip Whisper's special tokens (`<|startoftranscript|>`, `<|1.52|>`, …) from segment text.
        // `withoutTimestamps` is deliberately left false: it also disables the decoder's per-sentence
        // segment splitting (confirmed by trial — turning it on collapsed a 4-sentence clip into one
        // giant segment), which would destroy the segment-level timestamps everything downstream
        // needs (karaoke seek targets, ad-range boundaries).
        let decodeOptions = DecodingOptions(skipSpecialTokens: true, withoutTimestamps: false)
        let results = try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: decodeOptions)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let text = seg.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(text: text,
                                                  startMs: Int(seg.start * 1000),
                                                  endMs: Int(seg.end * 1000)))
            }
        }
        return Transcript(episodeId: "", source: .asr, format: "asr",
                          modelVersion: identifier, segments: segments)
    }

    public enum EngineError: Error, CustomStringConvertible {
        case notLoaded
        public var description: String { "WhisperKitASR.load() did not populate the pipeline" }
    }
}
