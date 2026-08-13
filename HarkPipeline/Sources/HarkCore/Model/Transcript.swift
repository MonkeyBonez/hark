import Foundation

/// A single timestamped transcript segment — the one source of truth every feature reads from.
///
/// Time is stored in **raw milliseconds** (never a segment index or FK) so that re-transcription
/// with a better model can never dangle a snip that referenced it (PRD §9.4).
public struct TranscriptSegment: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public var text: String
    public var startMs: Int
    public var endMs: Int
    /// Anonymized diarization cluster ("SPEAKER_0") or resolved name ("Host"). Nil until diarized.
    public var speaker: String?

    public init(id: UUID = UUID(), text: String, startMs: Int, endMs: Int, speaker: String? = nil) {
        self.id = id
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
    }

    public var durationMs: Int { max(0, endMs - startMs) }
}

/// A full episode transcript plus its provenance (PRD §9.4: source/format/modelVersion).
public struct Transcript: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable {
        case official   // Podcasting 2.0 <podcast:transcript>, normalized + quality-gated
        case asr        // on-device SpeechTranscriber / WhisperKit
    }

    public var episodeId: String
    public var source: Source
    /// e.g. "srt", "vtt", "html-normalized", "asr"
    public var format: String
    /// Identifier of the ASR/normalizer that produced this, for stage re-runs on model upgrade.
    public var modelVersion: String
    public var segments: [TranscriptSegment]

    public init(episodeId: String, source: Source, format: String, modelVersion: String, segments: [TranscriptSegment]) {
        self.episodeId = episodeId
        self.source = source
        self.format = format
        self.modelVersion = modelVersion
        self.segments = segments
    }

    public var durationMs: Int { segments.last?.endMs ?? 0 }
    public var fullText: String { segments.map(\.text).joined(separator: " ") }

    /// True iff this transcript carries any speaker labels (official SRT/VTT usually do not →
    /// diarization must still run on that path, PRD §9.3).
    public var hasSpeakers: Bool { segments.contains { $0.speaker != nil } }
}
