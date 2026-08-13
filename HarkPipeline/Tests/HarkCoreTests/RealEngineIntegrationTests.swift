import XCTest
@testable import HarkCore

/// Integration tests against the REAL Apple-framework adapters (Foundation Models, NL embeddings).
/// These make live on-device model calls — no mocks. They skip gracefully (XCTSkip) if Apple
/// Intelligence isn't available in the environment (e.g. a CI runner), rather than failing red;
/// on a machine with Apple Intelligence enabled (like the dev Mac this was built on) they run for real.
final class RealEngineIntegrationTests: XCTestCase {

    private func requireFoundationModels() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26+") }
        #else
        throw XCTSkip("FoundationModels not importable in this environment")
        #endif
    }

    func testFoundationModelsAdDetectorFlagsOnlySponsorSegment() async throws {
        try requireFoundationModels()
        guard #available(macOS 26.0, *) else { return }

        // The planted sponsor read is 25s across 3 segments — realistic ad length (host reads run
        // 20–90s; the detector's aggregation intentionally drops isolated flags < 8s as noise).
        let segs = [
            TranscriptSegment(text: "Welcome back, today we're talking about focus and deep work.", startMs: 0, endMs: 5000),
            TranscriptSegment(text: "The core idea is protecting long uninterrupted blocks of time.", startMs: 5000, endMs: 10000),
            TranscriptSegment(text: "This episode is sponsored by Acme Notes, the best way to organize your thinking.", startMs: 10000, endMs: 19000),
            TranscriptSegment(text: "Acme Notes syncs across all your devices and keeps everything searchable forever.", startMs: 19000, endMs: 27000),
            TranscriptSegment(text: "Use promo code FOCUS for twenty percent off your first year at acme dot com slash focus.", startMs: 27000, endMs: 35000),
            TranscriptSegment(text: "So back to deep work, the calendar is your most honest planning tool.", startMs: 35000, endMs: 40000),
            TranscriptSegment(text: "Batch your shallow tasks and defend your mornings for the hard thinking.", startMs: 40000, endMs: 45000),
        ]
        let t = Transcript(episodeId: "it", source: .official, format: "fixture", modelVersion: "x", segments: segs)

        let detector = FoundationModelsAdDetector()
        try await detector.load()
        let ads = try await detector.detectAds(in: t)

        XCTAssertFalse(ads.isEmpty, "should detect the planted sponsor read")
        // Must overlap the sponsor block and must NOT swallow the intro content.
        XCTAssertTrue(ads.contains { $0.overlaps(startMs: 10000, endMs: 35000) })
        XCTAssertFalse(ads.contains { $0.overlaps(startMs: 0, endMs: 9000) }, "must not flag unrelated intro content as an ad")
        let totalAdMs = ads.reduce(0) { $0 + $1.durationMs }
        XCTAssertLessThanOrEqual(totalAdMs, 35000, "ad range should stay in the neighborhood of the sponsor block")
    }

    func testFoundationModelsIntelligenceProducesRealDigest() async throws {
        try requireFoundationModels()
        guard #available(macOS 26.0, *) else { return }

        let window = TranscriptWindow(id: 0, segments: [
            TranscriptSegment(text: "The biggest mistake teams make is treating every task as equally urgent.", startMs: 0, endMs: 5000),
            TranscriptSegment(text: "A weekly review that kills anything not moving the core metric fixes that.", startMs: 5000, endMs: 10000),
        ], estimatedTokens: 40)

        let engine = FoundationModelsIntelligence()
        try await engine.load()
        let notes = try await engine.mapWindow(window)
        XCTAssertFalse(notes.topicLabel.isEmpty)
        XCTAssertFalse(notes.salientPoints.isEmpty)

        let digest = try await engine.reduce(notes: [notes], adFreeText: window.text)
        XCTAssertFalse(digest.summary.tldr.isEmpty)
    }

    func testNLContextualEmbeddingDistinguishesUnrelatedContent() async throws {
        guard #available(macOS 13.0, *) else { throw XCTSkip("needs macOS 13+") }
        let embedder = try NLContextualEmbeddingEngine()
        try await embedder.load()

        let vectors = try await embedder.embed([
            "we discussed compound interest and long-term investing strategies",
            "then we talked about baking sourdough bread at home",
            "compound interest and investment strategy for retirement savings",
        ])
        XCTAssertEqual(vectors.count, 3)
        XCTAssertEqual(vectors[0].count, embedder.dimension)

        let simInvestingPair = SemanticSearch.cosine(vectors[0], vectors[2])
        let simUnrelatedPair = SemanticSearch.cosine(vectors[0], vectors[1])
        XCTAssertGreaterThan(simInvestingPair, simUnrelatedPair,
                             "two investing-topic segments should be more similar than investing-vs-baking")
    }
}
