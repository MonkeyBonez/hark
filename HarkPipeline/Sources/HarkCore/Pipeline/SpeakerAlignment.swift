import Foundation

/// Shared diarizer→transcript alignment (PRD §9.3's required alignment step), factored out so every
/// diarization backend (SpeakerKit, FluidAudio, …) aligns identically: each transcript segment is
/// labeled with whichever speaker span has the greatest time overlap with it; nil if none overlap.
public enum SpeakerAlignment {
    public struct SpeakerSpan: Sendable {
        public let label: String
        public let startMs: Int
        public let endMs: Int
        public init(label: String, startMs: Int, endMs: Int) {
            self.label = label; self.startMs = startMs; self.endMs = endMs
        }
    }

    public static func dominantLabel(startMs: Int, endMs: Int, in spans: [SpeakerSpan]) -> String? {
        var best: (label: String, overlap: Int)? = nil
        for span in spans {
            let overlap = min(endMs, span.endMs) - max(startMs, span.startMs)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap { best = (span.label, overlap) }
        }
        return best?.label
    }

    /// Returns the transcript with each segment's `speaker` set to its dominant span label.
    public static func align(_ transcript: Transcript, to spans: [SpeakerSpan]) -> Transcript {
        var out = transcript
        out.segments = transcript.segments.map { seg in
            var s = seg
            s.speaker = dominantLabel(startMs: seg.startMs, endMs: seg.endMs, in: spans)
            return s
        }
        return out
    }
}
