import Foundation

/// Merges LLM-generated content chapters with detected AdRanges into the single user-facing
/// chapter timeline (PRD §8.11, §9.5): ads become visible, labeled chapters the listener can see
/// coming and skip with one tap. This is deterministic post-processing — the LLM never sees or
/// titles ad content, so the ad-exclusion contract is untouched. The failure modes are trust-cheap
/// where auto-skip's are not: a false positive is a mislabeled chapter, not silently eaten content;
/// a miss is just an unflagged ad.
public enum ChapterAssembly {

    /// Title for inserted ad chapters. Uniform and honest — confidence styling is a UI decision.
    public static let adChapterTitle = "Sponsor break"

    /// No chapter thinner than one minute exists in the timeline (user policy, 2026-07-09):
    ///  • a detected ad shorter than this never becomes a chapter and never splits content — it
    ///    simply stays "part of the chapter before" (the AdRange still exists for scrubber
    ///    regions and skip-eligibility, which are separate policies);
    ///  • a content fragment left shorter than this by a split is dropped rather than shown;
    ///  • a natively-short LLM chapter is absorbed into its content neighbor.
    public static let minChapterMs = 60_000

    /// Build the merged timeline. Content chapters overlapping a chapter-worthy ad are split at
    /// the ad boundaries and resume under the same title. Ranges the user marked "Not an ad" are
    /// ignored entirely (trust loop, §8.11).
    public static func timeline(content: [Chapter], ads: [AdRange]) -> [Chapter] {
        // Only minute-plus ads enter the timeline at all.
        let effective = coalesce(ads.filter { $0.userVerdict != .notAnAd })
            .filter { $0.durationMs >= minChapterMs }
        let sortedContent = content.sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
        guard !effective.isEmpty else { return absorbShort(sortedContent) }

        var out: [Chapter] = effective.map {
            Chapter(title: adChapterTitle, startMs: $0.startMs, endMs: $0.endMs)
        }

        for chapter in sortedContent {
            var pieces: [(start: Int, end: Int)] = [(chapter.startMs, chapter.endMs)]
            for ad in effective {
                pieces = pieces.flatMap { piece -> [(start: Int, end: Int)] in
                    guard ad.overlaps(startMs: piece.start, endMs: piece.end) else { return [piece] }
                    var kept: [(start: Int, end: Int)] = []
                    if ad.startMs > piece.start { kept.append((piece.start, ad.startMs)) }
                    if ad.endMs < piece.end { kept.append((ad.endMs, piece.end)) }
                    return kept
                }
            }
            out.append(contentsOf: pieces
                .filter { $0.end - $0.start >= minChapterMs }
                .map { Chapter(title: chapter.title, startMs: $0.start, endMs: $0.end) })
        }
        return absorbShort(out.sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) })
    }

    /// Final pass: a sub-minute CONTENT chapter is absorbed into an adjacent content chapter
    /// (previous preferred, next if it's first), or dropped when its only neighbors are ad
    /// chapters — a "Sponsor break" pill is never stretched over real content (trust: mislabeling
    /// content as ad is the failure mode this whole feature exists to avoid). Ad chapters are
    /// minute-plus by construction.
    static func absorbShort(_ chapters: [Chapter]) -> [Chapter] {
        var out: [Chapter] = []
        var deferred: Chapter?   // short leading chapter waiting for a content successor
        for chapter in chapters {
            let isShort = chapter.endMs - chapter.startMs < minChapterMs
            let isAd = chapter.title == adChapterTitle
            if isShort, !isAd {
                if let last = out.last, last.title != adChapterTitle {
                    out[out.count - 1].endMs = max(last.endMs, chapter.endMs)
                } else if out.isEmpty {
                    deferred = chapter
                }
                // else: previous is an ad chapter — drop the fragment.
                continue
            }
            var chapter = chapter
            if let lead = deferred, !isAd {
                chapter.startMs = min(chapter.startMs, lead.startMs)
                deferred = nil
            }
            out.append(chapter)
        }
        if out.isEmpty, let lead = deferred { out.append(lead) }
        return out
    }

    /// Sort + merge overlapping/touching ranges so the timeline never shows two ad pills back to
    /// back. (Upstream aggregation already gap-merges at 20s — D25 — this only guards overlaps.)
    static func coalesce(_ ads: [AdRange]) -> [AdRange] {
        let sorted = ads.sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
        var out: [AdRange] = []
        for ad in sorted {
            if var last = out.last, ad.startMs <= last.endMs {
                last.endMs = max(last.endMs, ad.endMs)
                last.confidence = max(last.confidence, ad.confidence)
                out[out.count - 1] = last
            } else {
                out.append(ad)
            }
        }
        return out
    }
}
