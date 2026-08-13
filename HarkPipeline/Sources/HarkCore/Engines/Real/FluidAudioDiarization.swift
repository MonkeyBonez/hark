import Foundation
import FluidAudio

/// Diarization adapter for **FluidAudio** (FluidInference, Apache-2.0, pyannote-style Core ML) —
/// the second PRD §9.3 diarization candidate, run against `SpeakerKitDiarization` on the same
/// episodes. Models download on first use via `DiarizerModels.downloadIfNeeded()`.
///
/// API verified against the actual v0.15.5 source (not guessed): `DiarizerManager(config:)` →
/// `initialize(models:)` → `performCompleteDiarization(samples, sampleRate:)` returns
/// `DiarizationResult.segments: [TimedSpeakerSegment]` with `speakerId: String` + start/end seconds.
/// Alignment to transcript segments uses the shared `SpeakerAlignment` helper.
public actor FluidAudioDiarization: DiarizationEngine {
    public let identifier: String
    public let approxResidentBytes: Int
    private var manager: DiarizerManager?

    public init(identifier: String = "fluidaudio-diarizer", approxResidentBytes: Int = 150 * 1_000_000) {
        self.identifier = identifier
        self.approxResidentBytes = approxResidentBytes
    }

    public func load() async throws {
        guard manager == nil else { return }
        let m = DiarizerManager()
        let models = try await DiarizerModels.downloadIfNeeded()
        m.initialize(models: models)
        self.manager = m
    }

    public func unload() async {
        manager?.cleanup()
        manager = nil
    }

    public func diarize(audioURL: URL, transcript: Transcript) async throws -> Transcript {
        if manager == nil { try await load() }
        guard let manager else { throw EngineError.notLoaded }

        let samples = try AudioConverter().resampleAudioFile(audioURL)   // 16kHz mono floats
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)

        let spans = result.segments.map {
            SpeakerAlignment.SpeakerSpan(label: "SPEAKER_\($0.speakerId)",
                                         startMs: Int($0.startTimeSeconds * 1000),
                                         endMs: Int($0.endTimeSeconds * 1000))
        }
        return SpeakerAlignment.align(transcript, to: spans)
    }

    public enum EngineError: Error, CustomStringConvertible {
        case notLoaded
        public var description: String { "FluidAudioDiarization.load() did not populate the manager" }
    }
}
