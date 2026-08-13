#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Segment-granular ad detection via Apple Foundation Models (PRD §9.3; fixes E7).
///
/// The model is shown a numbered batch of transcript lines and returns **which line numbers are
/// advertisements** — so AdRanges are tight around the actual sponsor segments, never whole map
/// windows. Runs before the LLM map, so ad text is removed before summarization. A cheap keyword
/// pre-pass (promo codes / "brought to you by") boosts recall on obvious reads.
@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelsAdDetector: AdDetectionEngine {
    public let identifier: String
    public var approxResidentBytes: Int { 0 } // OS-resident model
    /// Lines per model call — small enough to keep classification accurate and within context.
    public let batchSize: Int
    /// Second-pass block verification (D29). Measured on the 7-episode corpus: precision 2–3x up
    /// on EVERY episode, recall identical on every episode, ~0.4s/block. Default ON.
    public let verifyPass: Bool

    public init(identifier: String = "apple-foundation-models-ads", batchSize: Int = 12,
                verifyPass: Bool = true) {
        self.identifier = identifier
        self.batchSize = batchSize
        self.verifyPass = verifyPass
    }

    public func load() async throws {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            throw FoundationModelsIntelligence.EngineError.unavailable("\(reason)")
        }
    }

    @Generable
    struct AdVerdict {
        @Guide(description: "The 1-based line numbers that are advertisements or sponsor reads. Empty if none.")
        var adLineNumbers: [Int]
    }

    public func detectAds(in transcript: Transcript) async throws -> [AdRange] {
        let segments = transcript.segments
        guard !segments.isEmpty else { return [] }

        var adIndices = Set<Int>()

        // Keyword pre-pass — obvious reads, high precision (also a floor if the model whiffs).
        for (i, seg) in segments.enumerated() {
            let t = seg.text.lowercased()
            if t.contains("promo code") || t.contains("use code") || t.contains("dot com slash")
                || t.contains("brought to you by") || t.contains("sponsored by") {
                adIndices.insert(i)
            }
        }

        // Model pass over batches.
        var batchStart = 0
        while batchStart < segments.count {
            let batchEnd = min(batchStart + batchSize, segments.count)
            let batch = Array(segments[batchStart..<batchEnd])
            let numbered = batch.enumerated()
                .map { "\($0.offset + 1). \($0.element.text)" }
                .joined(separator: "\n")

            let instructions = """
                You label podcast transcript lines. A line is an advertisement if it promotes a
                product/service, reads a sponsor message, or gives a promo code or URL. Host banter,
                interviews, and normal show content are NOT ads. Return only the ad line numbers.
                """
            // Guided generation first; plain-text fallback on refusal (E16: guided generation
            // refuses real transcript content that plain generation accepts). A silently-dropped
            // batch is a hidden recall killer, so the fallback matters here as much as in the map.
            do {
                let session = LanguageModelSession(model: FoundationModelsIntelligence.permissiveModel, instructions: instructions)
                let verdict = try await session.respond(
                    to: "Lines:\n\(numbered)", generating: AdVerdict.self).content
                for n in verdict.adLineNumbers where n >= 1 && n <= batch.count {
                    adIndices.insert(batchStart + (n - 1))
                }
            } catch {
                do {
                    let session = LanguageModelSession(model: FoundationModelsIntelligence.permissiveModel, instructions: instructions)
                    let reply = try await session.respond(to: """
                        Lines:\n\(numbered)

                        Reply with ONLY the advertisement line numbers, comma-separated (e.g. "3,4,5"),
                        or the word NONE.
                        """).content
                    for tok in reply.split(whereSeparator: { !$0.isNumber }) {
                        if let n = Int(tok), n >= 1, n <= batch.count {
                            adIndices.insert(batchStart + (n - 1))
                        }
                    }
                } catch {
                    // Both decode paths failed on this batch: keep keyword-pass results, don't abort.
                }
            }
            batchStart = batchEnd
        }

        // Turn the flagged segment indices into merged AdRanges.
        //
        // Aggregation tuning (measured iteration, Phase B.4): ground-truth scoring showed the raw
        // per-line flags produce scattered micro-ranges — catching 1–2 sentences of a 60s sponsor
        // read and misfiring on isolated narrative lines (median sponsor-F1 0.23 across 7 real
        // episodes). Real ad reads are contiguous 20s+ blocks; distinct ad breaks sit minutes apart.
        // So: (1) merge flagged ranges whose gap is ≤ 20s — flags at the start and end of a read
        // bridge its middle; (2) after merging, drop isolated flags < 8s that never merged with a
        // neighbor — the classic single-line false positive.
        let flaggedRanges = adIndices.sorted().map {
            AdRange(startMs: segments[$0].startMs, endMs: segments[$0].endMs, confidence: 0.8)
        }
        let candidates = merge(flaggedRanges, gapMs: 20_000)
            .filter { $0.durationMs >= 8_000 }
        return verifyPass ? await verifyAds(candidates, in: transcript) : candidates
    }

    // MARK: - Second-pass block verification (the ad-precision experiment, Phase B verdict)

    @Generable
    struct BlockVerdict {
        @Guide(description: "true if this block is a paid advertisement, sponsor read, or promotional insert; false if it is normal show content")
        var isAd: Bool
    }

    /// Re-examines each MERGED candidate block with one focused yes/no call over its full text.
    /// The per-line pass has decent recall but flags genuine discussion *about* products/companies
    /// (measured precision ~20–33%); seeing a whole 20–90s block at once is exactly the context
    /// that separates "sponsor read" from "hosts discussing a company". Cheap: D25 aggregation
    /// leaves only ~6–11 blocks per episode.
    ///
    /// Fail-open: if both decode paths fail (E16 refusals), the block is KEPT — the verify pass
    /// exists to raise precision, but a refused call must not silently sacrifice recall (the ad
    /// gate also has a ≥0.90 recall floor on host reads).
    public func verifyAds(_ candidates: [AdRange], in transcript: Transcript) async -> [AdRange] {
        var kept: [AdRange] = []
        for range in candidates {
            let blockText = transcript.segments
                .filter { range.overlaps(startMs: $0.startMs, endMs: $0.endMs) }
                .map(\.text).joined(separator: " ")
            if blockText.isEmpty {
                kept.append(range)
            } else if (await isSponsorRead(blockText)) ?? true {
                kept.append(range)
            }
        }
        return kept
    }

    /// One block verdict. Returns nil if both decode paths failed (caller decides the default).
    private func isSponsorRead(_ blockText: String) async -> Bool? {
        let instructions = """
            You verify whether a block of podcast transcript is an ADVERTISEMENT. An advertisement
            is a paid sponsor read or promotional insert: it pitches a product/service directly to
            the listener, often with offers, URLs, or discount codes, and interrupts the show's
            actual topic. Hosts or guests DISCUSSING a company, product, or business as part of the
            show's subject matter is NOT an advertisement, even if they praise it. A host briefly
            mentioning their own other episodes, newsletter, book, or community is CONTENT, not an
            advertisement (self-promotion is not a paid ad).
            """
        do {
            let session = LanguageModelSession(model: FoundationModelsIntelligence.permissiveModel, instructions: instructions)
            return try await session.respond(
                to: "Block:\n\(blockText)", generating: BlockVerdict.self).content.isAd
        } catch {
            // Plain-text fallback on refusal (E16: guided generation refuses real transcript
            // content that plain generation accepts).
            do {
                let session = LanguageModelSession(model: FoundationModelsIntelligence.permissiveModel, instructions: instructions)
                let reply = try await session.respond(to: """
                    Block:\n\(blockText)

                    Answer with EXACTLY one word: AD if this block is an advertisement/sponsor read,
                    or CONTENT if it is normal show content.
                    """).content
                let up = reply.uppercased()
                if up.contains("CONTENT") { return false }
                if up.contains("AD") { return true }
                return nil
            } catch {
                return nil
            }
        }
    }

    private func merge(_ ranges: [AdRange], gapMs: Int) -> [AdRange] {
        let sorted = ranges.sorted { $0.startMs < $1.startMs }
        var out: [AdRange] = []
        for r in sorted {
            if var last = out.last, r.startMs <= last.endMs + gapMs {
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
#endif
