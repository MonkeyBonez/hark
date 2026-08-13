import Foundation

/// Zero-model ad detector for Tier-2 devices (no Apple Intelligence → no FM detector, and the
/// MLX ad path isn't built). Deliberately conservative: flags only unambiguous sponsor-read
/// phrasing, then applies the same D25 aggregation as the FM detector (merge ≤20s gaps, drop <8s
/// isolates). High precision / modest recall is the right trade here — a missed ad is an ordinary
/// podcast moment, a false flag erodes trust (§8.11). This is the same keyword pre-pass the FM
/// detector runs as its recall floor, promoted to a standalone engine.
public struct KeywordAdDetector: AdDetectionEngine {
    public let identifier: String
    public var approxResidentBytes: Int { 0 }

    /// Phrases that essentially never occur outside a sponsor read.
    static let sponsorPhrases = [
        "promo code", "use code", "coupon code", "discount code",
        "dot com slash", ".com/", "sponsored by", "brought to you by",
        "this episode is supported by", "terms apply", "free trial when you",
    ]

    public init(identifier: String = "keyword-ads") {
        self.identifier = identifier
    }

    public func detectAds(in transcript: Transcript) async throws -> [AdRange] {
        var flagged: [AdRange] = []
        for seg in transcript.segments {
            let t = seg.text.lowercased()
            if Self.sponsorPhrases.contains(where: { t.contains($0) }) {
                flagged.append(AdRange(startMs: seg.startMs, endMs: seg.endMs, confidence: 0.6))
            }
        }
        // D25 aggregation: bridge flags across a read (≤20s gaps), then kill isolated one-liners.
        var merged: [AdRange] = []
        for r in flagged.sorted(by: { $0.startMs < $1.startMs }) {
            if var last = merged.last, r.startMs <= last.endMs + 20_000 {
                last.endMs = max(last.endMs, r.endMs)
                last.confidence = max(last.confidence, r.confidence)
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        return merged.filter { $0.durationMs >= 8_000 }
    }
}
