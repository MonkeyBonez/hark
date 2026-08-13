#if canImport(MLXLLM)
import Foundation

/// Ad detection for the shipping single-model app (D38): the same two-stage architecture as the
/// FM detector (D29) — model-classified candidates, then a per-block verify pass — but every model
/// call runs on the **bundled MLX model** instead of Apple Foundation Models.
///
/// It **shares** the run's `MLXIntelligence` actor rather than owning a second model. The
/// orchestrator runs ad-detect immediately before the LLM map/reduce; a separate model would load
/// ~1.1GB of weights twice per episode. So `load()` warms the shared model, `unload()` is a no-op
/// (the map stage needs it resident right after), and the single-model-resident invariant holds
/// because there is only ever one model.
///
/// Candidate stage = keyword pre-pass (unambiguous sponsor phrasing, high precision) **plus a
/// per-line MLX classification pass over small batches**. The per-line model pass is required, not
/// optional: measured 2026-07-20, keyword candidates alone found ZERO of founders-402's three
/// host-read sponsor ads (Ramp/Vanta/Collateral never say "promo code") → F1 0.00. The verify pass
/// can only shrink the candidate set, so recall lives or dies on this stage. Then D25 aggregation
/// (merge ≤20s, drop <8s) and the verify pass. Wall-time cost: ~1 MLX call per `batchSize` lines
/// (~30–90s added on a full episode) — the price of recall; `batchSize` is the speed lever.
public actor MLXAdDetector: AdDetectionEngine {
    public nonisolated let identifier: String
    /// The shared model reports the real resident cost; the detector adds none of its own.
    public nonisolated var approxResidentBytes: Int { backing.approxResidentBytes }

    private let backing: MLXIntelligence
    /// Lines per classification call — small keeps the model accurate and the reply short.
    private let batchSize: Int
    /// Second-pass block verification (D29). Default ON — precision is the point; recall is
    /// protected by fail-open (see `verifyAds`).
    private let verifyPass: Bool

    public init(backing: MLXIntelligence, verifyPass: Bool = true, batchSize: Int = 12,
                identifier: String = "mlx-ads") {
        self.backing = backing
        self.verifyPass = verifyPass
        self.batchSize = batchSize
        self.identifier = identifier
    }

    public func load() async throws { try await backing.load() }

    /// No-op: the shared model must stay resident for the map/reduce stage the orchestrator runs
    /// immediately after ad-detect. The owner (`MLXIntelligence`) is unloaded once, at end of run.
    public func unload() async {}

    public func detectAds(in transcript: Transcript) async throws -> [AdRange] {
        let segments = transcript.segments
        guard !segments.isEmpty else { return [] }

        var adIndices = Set<Int>()

        // Keyword pre-pass — obvious reads, high precision, and a floor if the model whiffs.
        for (i, seg) in segments.enumerated() {
            let t = seg.text.lowercased()
            if KeywordAdDetector.sponsorPhrases.contains(where: { t.contains($0) }) {
                adIndices.insert(i)
            }
        }

        // Per-line MLX classification over batches (the recall engine — see the type doc).
        var batchStart = 0
        while batchStart < segments.count {
            let batchEnd = min(batchStart + batchSize, segments.count)
            let batch = Array(segments[batchStart..<batchEnd])
            let numbered = batch.enumerated()
                .map { "\($0.offset + 1). \($0.element.text)" }
                .joined(separator: "\n")
            if let nums = await classifyBatch(numbered, count: batch.count) {
                for n in nums where n >= 1 && n <= batch.count {
                    adIndices.insert(batchStart + (n - 1))
                }
            }
            batchStart = batchEnd
        }

        // Flagged segment indices → merged AdRanges (D25: bridge ≤20s gaps, kill <8s isolates).
        let flagged = adIndices.sorted().map {
            AdRange(startMs: segments[$0].startMs, endMs: segments[$0].endMs, confidence: 0.8)
        }
        let candidates = merge(flagged, gapMs: 20_000).filter { $0.durationMs >= 8_000 }
        guard verifyPass, !candidates.isEmpty else { return candidates }
        return await verifyAds(candidates, in: transcript)
    }

    /// One batch verdict: the 1-based ad line numbers, or nil on failure (keyword floor stands).
    private func classifyBatch(_ numbered: String, count: Int) async -> [Int]? {
        let instructions = """
            You label podcast transcript lines. A line is an advertisement if it promotes a
            product/service, reads a sponsor message, or gives a promo code or URL. Host banter,
            interviews, and normal show content are NOT ads. Return only the ad line numbers.
            """
        do {
            let reply = try await backing.respond(instructions: instructions, prompt: """
                Lines:
                \(numbered)

                Reply with ONLY the advertisement line numbers, comma-separated (e.g. "3,4,5"),
                or the word NONE.
                """)
            // Any numbers in the reply are line numbers; the n <= count filter above discards echoes.
            return reply.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        } catch {
            return nil
        }
    }

    // MARK: - Second-pass block verification (D29 semantics, MLX line-format)

    /// Re-examines each merged candidate block with one focused verdict call over its full text.
    /// Fail-open: an unparseable/failed verdict KEEPS the block — verify raises precision but must
    /// never silently sacrifice recall (the ad gate has a recall floor on host reads).
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

    /// One block verdict via the shared MLX model. Returns nil if the reply can't be parsed
    /// (caller fails open).
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
            let reply = try await backing.respond(instructions: instructions, prompt: """
                Block:
                \(blockText)

                Answer with EXACTLY one line, no other text:
                VERDICT: ad
                or
                VERDICT: content
                """)
            return Self.parseVerdict(reply)
        } catch {
            return nil
        }
    }

    /// Parse the VERDICT line. Returns true (ad), false (content), or nil (unparseable → fail-open).
    /// Exposed for unit testing without a model. Checks `content` before `ad` and matches the
    /// verdict value only after the colon, so a company name containing "ad" in the block echo
    /// can't flip the result.
    static func parseVerdict(_ reply: String) -> Bool? {
        for rawLine in reply.split(whereSeparator: \.isNewline) {
            let line = rawLine.lowercased()
            guard let colon = line.range(of: "verdict:") else { continue }
            let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("content") { return false }
            if value.hasPrefix("ad") { return true }
        }
        return nil
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
