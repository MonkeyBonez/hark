import Foundation

/// The ad-exclusion contract (PRD §9.5). Summarization and key-moment inputs are the transcript
/// **minus** detected AdRanges — a TL;DR that summarizes a sponsor read is a trust catastrophe for
/// this product. Also validates that proposed key moments never fall inside an ad. Bonus: 10–20%
/// fewer input tokens.
public enum AdExclusion {

    /// Returns the transcript segments with any segment that overlaps a detected ad removed.
    public static func adFreeSegments(_ transcript: Transcript, ads: [AdRange]) -> [TranscriptSegment] {
        guard !ads.isEmpty else { return transcript.segments }
        return transcript.segments.filter { seg in
            !ads.contains { $0.overlaps(startMs: seg.startMs, endMs: seg.endMs) }
        }
    }

    /// The ad-free plain text fed to the reduce stage.
    public static func adFreeText(_ transcript: Transcript, ads: [AdRange]) -> String {
        adFreeSegments(transcript, ads: ads).map(\.text).joined(separator: " ")
    }

    /// A transcript with ad segments removed — this is what the LLM map/reduce actually sees, so the
    /// model never summarizes a sponsor read (E7 fix: exclusion happens BEFORE chunking, not after).
    public static func adFreeTranscript(_ transcript: Transcript, ads: [AdRange]) -> Transcript {
        var t = transcript
        t.segments = adFreeSegments(transcript, ads: ads)
        return t
    }

    /// Drops any key moment that overlaps a detected ad — the validation step the PRD requires.
    public static func validate(keyMoments: [KeyMoment], against ads: [AdRange]) -> [KeyMoment] {
        keyMoments.filter { km in
            !ads.contains { $0.overlaps(startMs: km.startMs, endMs: km.endMs) }
        }
    }

    /// Player-side skip-eligibility floor (PRD §8.11, user decision 2026-07-09): only detected
    /// ranges at least this long are ever auto-skipped or Ask-prompted. Shorter detections (a 3s
    /// self-mention, a one-line segue) still render as scrubber regions but never interrupt —
    /// the interruption costs more trust than the seconds it saves.
    public static let minSkippableAdMs = 30_000

    /// The ranges the player may act on (skip/Ask). Chapters and scrubber regions use the full
    /// list; this is the actionable subset.
    public static func skippable(_ ads: [AdRange]) -> [AdRange] {
        ads.filter { $0.durationMs >= minSkippableAdMs && $0.userVerdict != .notAnAd }
    }

    /// Fraction of transcript wall-time classified as ads (reported in the run record).
    public static func adFraction(_ transcript: Transcript, ads: [AdRange]) -> Double {
        let total = transcript.durationMs
        guard total > 0 else { return 0 }
        let adMs = ads.reduce(0) { $0 + $1.durationMs }
        return min(1.0, Double(adMs) / Double(total))
    }
}
