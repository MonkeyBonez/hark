import Foundation
import SpeakerKit
import WhisperKit   // AudioProcessor.loadAudioAsFloatArray

/// Diarization adapter for **SpeakerKit** (Argmax, pyannote Core ML) — one of the two PRD §9.3
/// diarization candidates (the other, FluidAudio, is not yet wired). Downloads pyannote models on
/// first use via the default `PyannoteConfig`.
///
/// Alignment: SpeakerKit's diarization runs on raw audio and returns its own `SpeakerSegment` time
/// ranges, independent of our transcript's segment boundaries — so each `TranscriptSegment` is
/// labeled with whichever speaker cluster has the greatest **time overlap** with it (the alignment
/// step the PRD calls out as required, §9.3).
public actor SpeakerKitDiarization: DiarizationEngine {
    public let identifier: String
    public let approxResidentBytes: Int
    private var kit: SpeakerKit?

    public init(identifier: String = "speakerkit-pyannote", approxResidentBytes: Int = 150 * 1_000_000) {
        self.identifier = identifier
        self.approxResidentBytes = approxResidentBytes
    }

    public func load() async throws {
        guard kit == nil else { return }
        kit = try await SpeakerKit()
    }

    public func unload() async {
        await kit?.unloadModels()
        kit = nil
    }

    public func diarize(audioURL: URL, transcript: Transcript) async throws -> Transcript {
        if kit == nil { try await load() }
        guard let kit else { throw EngineError.notLoaded }

        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        let result = try await kit.diarize(audioArray: samples)

        // Shared alignment (SpeakerAlignment): dominant time-overlap span labels each segment.
        let spans = result.segments.compactMap { seg -> SpeakerAlignment.SpeakerSpan? in
            guard let id = seg.speaker.speakerId else { return nil }
            return SpeakerAlignment.SpeakerSpan(label: "SPEAKER_\(id)",
                                                startMs: Int(seg.startTime * 1000),
                                                endMs: Int(seg.endTime * 1000))
        }
        return SpeakerAlignment.align(transcript, to: spans)
    }

    public enum EngineError: Error, CustomStringConvertible {
        case notLoaded
        public var description: String { "SpeakerKitDiarization.load() did not populate the pipeline" }
    }
}
