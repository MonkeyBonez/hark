import Foundation

/// Objective scoring for the bake-off. Summary/digest quality is NOT scored here — it needs an
/// LLM-judge or human rubric (see docs/P0-scoring-rubric.md); the harness records the digest text
/// for later scoring. ASR (WER) and ad detection (F1 over time) are scored objectively.
public enum Scoring {

    // MARK: - Word Error Rate (ASR)

    /// Standard WER = (substitutions + insertions + deletions) / reference words, via word-level
    /// Levenshtein. Both strings are lightly normalized (lowercased, punctuation stripped).
    public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = normalizeWords(reference)
        let hyp = normalizeWords(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        let distance = levenshtein(ref, hyp)
        return Double(distance) / Double(ref.count)
    }

    static func normalizeWords(_ s: String) -> [String] {
        s.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
    }

    static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    // MARK: - Ad detection F1 (time-overlap based)

    /// Precision/recall/F1 computed on a per-millisecond-of-audio basis: how much predicted ad time
    /// overlaps labeled ad time. Robust to boundary jitter, unlike range-count matching.
    public static func adScore(predicted: [AdRange], labeled: [AdRange], episodeDurationMs: Int) -> QualityScore {
        let predMs = coveredMillis(predicted, cap: episodeDurationMs)
        let labelMs = coveredMillis(labeled, cap: episodeDurationMs)
        let overlap = overlapMillis(predicted, labeled, cap: episodeDurationMs)

        let precision = predMs > 0 ? Double(overlap) / Double(predMs) : (labelMs == 0 ? 1 : 0)
        let recall = labelMs > 0 ? Double(overlap) / Double(labelMs) : (predMs == 0 ? 1 : 0)
        let f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0
        let fraction = episodeDurationMs > 0 ? Double(predMs) / Double(episodeDurationMs) : 0
        return QualityScore(adPrecision: precision, adRecall: recall, adF1: f1, adFractionDetected: fraction)
    }

    /// Total covered milliseconds after merging overlaps.
    static func coveredMillis(_ ranges: [AdRange], cap: Int) -> Int {
        let merged = merge(ranges.map { (max(0, $0.startMs), min(cap, $0.endMs)) })
        return merged.reduce(0) { $0 + max(0, $1.1 - $1.0) }
    }

    static func overlapMillis(_ a: [AdRange], _ b: [AdRange], cap: Int) -> Int {
        let ma = merge(a.map { (max(0, $0.startMs), min(cap, $0.endMs)) })
        let mb = merge(b.map { (max(0, $0.startMs), min(cap, $0.endMs)) })
        var total = 0
        for (s1, e1) in ma {
            for (s2, e2) in mb {
                total += max(0, min(e1, e2) - max(s1, s2))
            }
        }
        return total
    }

    static func merge(_ ranges: [(Int, Int)]) -> [(Int, Int)] {
        let sorted = ranges.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var out: [(Int, Int)] = []
        for r in sorted {
            if let last = out.last, r.0 <= last.1 {
                out[out.count - 1].1 = max(last.1, r.1)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
