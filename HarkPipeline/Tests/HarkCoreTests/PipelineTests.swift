import XCTest
@testable import HarkCore

final class PipelineTests: XCTestCase {

    func testChunkerRespectsTokenBudget() {
        let segs = (0..<500).map { i in
            TranscriptSegment(text: "some words here for segment number \(i) about the topic", startMs: i * 5000, endMs: i * 5000 + 5000)
        }
        let t = Transcript(episodeId: "t", source: .asr, format: "asr", modelVersion: "x", segments: segs)
        let chunker = Chunker.forContextLimit(4096)
        let windows = chunker.windows(for: t)
        XCTAssertFalse(windows.isEmpty)
        for w in windows {
            // Every window fits the budget, unless it's a single over-long segment on its own.
            XCTAssertTrue(w.estimatedTokens <= chunker.targetTokens || w.segments.count == 1)
        }
        // Windows cover every segment (id monotonic, no gaps in coverage of first/last).
        XCTAssertEqual(windows.first?.segments.first?.startMs, 0)
    }

    func testAdExclusionRemovesSponsorText() {
        let segs = [
            TranscriptSegment(text: "real content one", startMs: 0, endMs: 1000),
            TranscriptSegment(text: "sponsored by acme promo code save", startMs: 1000, endMs: 2000),
            TranscriptSegment(text: "real content two", startMs: 2000, endMs: 3000),
        ]
        let t = Transcript(episodeId: "t", source: .asr, format: "asr", modelVersion: "x", segments: segs)
        let ads = [AdRange(startMs: 1000, endMs: 2000, confidence: 0.9)]
        let text = AdExclusion.adFreeText(t, ads: ads)
        XCTAssertFalse(text.contains("acme"))
        XCTAssertTrue(text.contains("real content one"))
        XCTAssertTrue(text.contains("real content two"))
    }

    func testKeyMomentValidationDropsAdOverlap() {
        let ads = [AdRange(startMs: 1000, endMs: 2000, confidence: 0.9)]
        let moments = [
            KeyMoment(title: "good", startMs: 3000, endMs: 4000),
            KeyMoment(title: "in-ad", startMs: 1500, endMs: 1800),
        ]
        let kept = AdExclusion.validate(keyMoments: moments, against: ads)
        XCTAssertEqual(kept.map(\.title), ["good"])
    }

    func testWERExactAndError() {
        XCTAssertEqual(Scoring.wordErrorRate(reference: "the quick brown fox", hypothesis: "the quick brown fox"), 0, accuracy: 0.0001)
        // one substitution out of four words = 25%
        XCTAssertEqual(Scoring.wordErrorRate(reference: "the quick brown fox", hypothesis: "the quick brown dog"), 0.25, accuracy: 0.0001)
    }

    func testAdF1PerfectOverlap() {
        let labeled = [AdRange(startMs: 1000, endMs: 2000, confidence: 1)]
        let pred = [AdRange(startMs: 1000, endMs: 2000, confidence: 0.8)]
        let s = Scoring.adScore(predicted: pred, labeled: labeled, episodeDurationMs: 5000)
        XCTAssertEqual(s.adF1 ?? 0, 1.0, accuracy: 0.0001)
    }

    func testOrchestratorEndToEndInvariants() async throws {
        let orch = PipelineOrchestrator(engines: .mock(label: "test", audioSeconds: 1800))
        let r = try await orch.process(episodeId: "e", audioURL: URL(fileURLWithPath: "/dev/null"), audioSeconds: 1800)
        XCTAssertFalse(r.artifacts.transcript.segments.isEmpty)
        XCTAssertFalse(r.artifacts.ads.isEmpty)                       // planted sponsor read detected
        XCTAssertNotNil(r.artifacts.digest)
        XCTAssertEqual(r.artifacts.embeddings.count, r.artifacts.transcript.segments.count)
        // ad-exclusion contract holds end-to-end
        let ads = r.artifacts.ads
        let leaks = (r.artifacts.digest?.keyMoments ?? []).filter { km in ads.contains { $0.overlaps(startMs: km.startMs, endMs: km.endMs) } }
        XCTAssertTrue(leaks.isEmpty)
    }

    func testE7_AdInsideSingleWindowKeepsContent() async throws {
        // Regression for E7: an ad living inside the only window must NOT wipe the episode's content.
        // Ads are removed at segment granularity before the map, so the digest stays real + ad-free.
        let segs = [
            TranscriptSegment(text: "welcome to the show today we talk about focus and deep work", startMs: 0, endMs: 5000),
            TranscriptSegment(text: "the core idea is protecting long uninterrupted blocks of time", startMs: 5000, endMs: 10000),
            TranscriptSegment(text: "this segment is sponsored by acme use promo code focus at acme dot com slash deal", startMs: 10000, endMs: 15000),
            TranscriptSegment(text: "so back to deep work the calendar is your most honest planning tool", startMs: 15000, endMs: 20000),
            TranscriptSegment(text: "batch shallow tasks and defend the mornings for the hard thinking", startMs: 20000, endMs: 25000),
        ]
        let t = Transcript(episodeId: "e7", source: .official, format: "fixture", modelVersion: "x", segments: segs)
        let orch = PipelineOrchestrator(engines: .mock(label: "e7", audioSeconds: 25))
        let r = try await orch.process(episodeId: "e7", audioURL: URL(fileURLWithPath: "/dev/null"),
                                       audioSeconds: 25, officialTranscript: t)

        // Exactly the sponsor segment is flagged — a TIGHT range, not the whole episode.
        XCTAssertFalse(r.artifacts.ads.isEmpty)
        let adMs = r.artifacts.ads.reduce(0) { $0 + $1.durationMs }
        XCTAssertLessThan(adMs, t.durationMs / 2, "ad range should be tight, not swallow the episode")
        // The digest survived: the model still had ad-free content to summarize.
        XCTAssertNotNil(r.artifacts.digest, "reduce must receive ad-free content, not be starved to empty")
        XCTAssertFalse(r.artifacts.digest?.chapters.isEmpty ?? true)
    }

    func testEngineUnavailabilityDegradesInsteadOfFailing() async throws {
        // The AI-off-device scenario (no Apple Intelligence → FM engines throw on load()):
        // the run must complete with transcript + embeddings intact, digest nil, degraded stages
        // recorded — NOT throw away the transcript ASR already produced. (Found live 2026-07-09:
        // bare `try load()` failed the whole run on unavailability.)
        struct UnavailableIntelligence: EpisodeIntelligenceEngine {
            struct Unavailable: Error {}
            let identifier = "unavailable-llm"
            let contextTokenLimit = 4096
            func load() async throws { throw Unavailable() }
            func mapWindow(_ window: TranscriptWindow) async throws -> WindowNotes { throw Unavailable() }
            func reduce(notes: [WindowNotes], adFreeText: String) async throws -> EpisodeDigest { throw Unavailable() }
            func enrichSnip(_ request: SnipEnrichmentRequest) async throws -> SnipEnrichment { throw Unavailable() }
            func nameSpeakers(introText: String, clusters: [String]) async throws -> [String: String] { throw Unavailable() }
        }
        struct UnavailableAdDetector: AdDetectionEngine {
            struct Unavailable: Error {}
            let identifier = "unavailable-ads"
            func load() async throws { throw Unavailable() }
            func detectAds(in transcript: Transcript) async throws -> [AdRange] { throw Unavailable() }
        }

        var set = EngineSet.mock(label: "ai-off-device", audioSeconds: 600)
        set.intelligence = UnavailableIntelligence()
        set.adDetector = UnavailableAdDetector()
        let orch = PipelineOrchestrator(engines: set)
        let r = try await orch.process(episodeId: "aioff", audioURL: URL(fileURLWithPath: "/dev/null"), audioSeconds: 600)

        XCTAssertFalse(r.artifacts.transcript.segments.isEmpty, "transcript must survive engine unavailability")
        XCTAssertEqual(r.artifacts.embeddings.count, r.artifacts.transcript.segments.count,
                       "embeddings still run — find-a-moment works on the degraded path")
        XCTAssertNil(r.artifacts.digest, "no digest without an intelligence engine")
        XCTAssertTrue(r.artifacts.ads.isEmpty)
        XCTAssertTrue(r.record.stages.contains { $0.stage == "llm" && $0.degraded })
        XCTAssertTrue(r.record.stages.contains { $0.stage == "ad-detect" && $0.degraded })
    }

    func testDegradeDoesNotDropAudio() async throws {
        // Force the memory guard to trip by demanding an absurd floor; transcript must survive.
        var set = EngineSet.mock(label: "degrade", audioSeconds: 600)
        set.intelligence = MockIntelligence(approxResidentBytes: 1)
        let orch = PipelineOrchestrator(engines: set, memoryGuard: MemoryGuard(floorBytes: Int.max - 1))
        let r = try await orch.process(episodeId: "d", audioURL: URL(fileURLWithPath: "/dev/null"), audioSeconds: 600)
        XCTAssertFalse(r.artifacts.transcript.segments.isEmpty)       // playback survives
        XCTAssertNil(r.artifacts.digest)                             // LLM stage degraded away
        XCTAssertTrue(r.record.stages.contains { $0.degraded })
    }

    func testAdLabelFileRoundTripAndSelfConsistency() throws {
        // Phase-B self-consistency gate: labels fed back as detections must score F1 ≈ 1.0.
        let labels = AdLabelFile(episodeId: "e", labeler: "test", ranges: [
            .init(startMs: 10_000, endMs: 40_000, category: .sponsor),
            .init(startMs: 100_000, endMs: 130_000, category: .sponsor, note: "midroll"),
            .init(startMs: 200_000, endMs: 210_000, category: .selfpromo, flagged: true),
        ])
        // JSON round-trip
        let data = try JSONEncoder().encode(labels)
        let decoded = try JSONDecoder().decode(AdLabelFile.self, from: data)
        XCTAssertEqual(decoded.ranges.count, 3)
        // Category filter: sponsor class excludes selfpromo
        let sponsorTruth = decoded.ranges(in: .sponsor)
        XCTAssertEqual(sponsorTruth.count, 2)
        // Self-consistency: perfect detections → F1 = 1.0
        let s = Scoring.adScore(predicted: sponsorTruth, labeled: sponsorTruth, episodeDurationMs: 300_000)
        XCTAssertEqual(s.adF1 ?? 0, 1.0, accuracy: 0.0001)
    }

    // MARK: - Chapter timeline (ads surfaced as visible chapters, PRD §8.11; 60s floor policy)

    func testChapterTimelineInsertsAdChapterAndSplitsContent() {
        // A minute-plus ad in the middle of a content chapter → chapter splits, ad chapter between.
        let content = [Chapter(title: "Deep work", startMs: 0, endMs: 240_000)]
        let ads = [AdRange(startMs: 60_000, endMs: 130_000, confidence: 0.7)]
        let merged = ChapterAssembly.timeline(content: content, ads: ads)
        XCTAssertEqual(merged.map(\.title), ["Deep work", ChapterAssembly.adChapterTitle, "Deep work"])
        XCTAssertEqual(merged.map(\.startMs), [0, 60_000, 130_000])
        XCTAssertEqual(merged.map(\.endMs), [60_000, 130_000, 240_000])
    }

    func testChapterTimelineShortAdNeverChaptersOrSplits() {
        // The two thresholds are INDEPENDENT (user policy 2026-07-09):
        //  • a few-seconds detection: neither chaptered nor skippable — stays part of the chapter.
        //  • a 45s detection: skippable (>30s floor) but NOT chaptered (<60s floor) — a mid-content
        //    sponsor read the player may skip, without fragmenting the chapter list around it.
        let content = [Chapter(title: "Deep work", startMs: 0, endMs: 240_000)]
        let tiny = [AdRange(startMs: 40_000, endMs: 45_000, confidence: 0.7)]     // 5s
        XCTAssertEqual(ChapterAssembly.timeline(content: content, ads: tiny), content)
        XCTAssertTrue(AdExclusion.skippable(tiny).isEmpty)

        let midLength = [AdRange(startMs: 40_000, endMs: 85_000, confidence: 0.7)] // 45s
        XCTAssertEqual(ChapterAssembly.timeline(content: content, ads: midLength), content)  // no chapter
        XCTAssertEqual(AdExclusion.skippable(midLength).count, 1)                            // but skippable
    }

    func testChapterTimelinePrerollAdAndNotAnAdVerdict() {
        // A minute-plus pre-roll gets its own chapter; a range the user marked "Not an ad" must
        // vanish from the timeline entirely (trust loop) even when it is minute-plus.
        let content = [Chapter(title: "Intro", startMs: 70_000, endMs: 200_000)]
        let ads = [
            AdRange(startMs: 0, endMs: 70_000, confidence: 0.9),
            AdRange(startMs: 90_000, endMs: 160_000, confidence: 0.6, userVerdict: .notAnAd),
        ]
        let merged = ChapterAssembly.timeline(content: content, ads: ads)
        XCTAssertEqual(merged.map(\.title), [ChapterAssembly.adChapterTitle, "Intro"])
        // The notAnAd range neither split "Intro" nor produced an ad chapter.
        XCTAssertEqual(merged[1].startMs, 70_000)
        XCTAssertEqual(merged[1].endMs, 200_000)
        // notAnAd is also excluded from the skippable set regardless of length.
        XCTAssertEqual(AdExclusion.skippable(ads).count, 1)
    }

    func testChapterTimelineDropsSliversAndCoalescesOverlappingAds() {
        // Two overlapping ad ranges coalesce into ONE minute-plus ad chapter; the sub-minute
        // content fragments the split leaves at each edge are dropped, never stretched over by
        // the ad pill.
        let content = [Chapter(title: "Main topic", startMs: 0, endMs: 150_000)]
        let ads = [
            AdRange(startMs: 30_000, endMs: 80_000, confidence: 0.7),
            AdRange(startMs: 75_000, endMs: 120_000, confidence: 0.8),   // overlaps the first
        ]
        let merged = ChapterAssembly.timeline(content: content, ads: ads)
        // Pieces: 0–30s (dropped, <60s) and 120–150s (dropped, <60s); one coalesced ad chapter.
        XCTAssertEqual(merged.map(\.title), [ChapterAssembly.adChapterTitle])
        XCTAssertEqual(merged[0].startMs, 30_000)
        XCTAssertEqual(merged[0].endMs, 120_000)
    }

    func testChapterTimelineAbsorbsNativelyShortChapters() {
        // A sub-minute LLM chapter merges into the previous content chapter; a sub-minute leading
        // chapter merges forward into the next one.
        let content = [
            Chapter(title: "Cold open", startMs: 0, endMs: 20_000),          // short leading → forward
            Chapter(title: "Main topic", startMs: 20_000, endMs: 200_000),
            Chapter(title: "Aside", startMs: 200_000, endMs: 230_000),       // short → into previous
            Chapter(title: "Second half", startMs: 230_000, endMs: 400_000),
        ]
        let merged = ChapterAssembly.timeline(content: content, ads: [])
        XCTAssertEqual(merged.map(\.title), ["Main topic", "Second half"])
        XCTAssertEqual(merged[0].startMs, 0)          // absorbed the cold open
        XCTAssertEqual(merged[0].endMs, 230_000)      // absorbed the aside
    }

    func testChapterTimelineNoAdsPassThrough() {
        let content = [
            Chapter(title: "B", startMs: 60_000, endMs: 120_000),
            Chapter(title: "A", startMs: 0, endMs: 60_000),
        ]
        let merged = ChapterAssembly.timeline(content: content, ads: [])
        XCTAssertEqual(merged.map(\.title), ["A", "B"])   // sorted, otherwise untouched
    }

    func testOrchestratorSurfacesAdsAsChapters() async throws {
        // End-to-end: the planted sponsor read must appear in the digest as a labeled ad chapter,
        // and no content chapter may overlap a detected ad range.
        let orch = PipelineOrchestrator(engines: .mock(label: "adchapters", audioSeconds: 1800))
        let r = try await orch.process(episodeId: "e", audioURL: URL(fileURLWithPath: "/dev/null"), audioSeconds: 1800)
        let chapters = try XCTUnwrap(r.artifacts.digest?.chapters)
        let ads = r.artifacts.ads

        XCTAssertTrue(chapters.contains { $0.title == ChapterAssembly.adChapterTitle },
                      "detected ad must surface as a visible chapter")
        let overlapping = chapters.filter { ch in
            ch.title != ChapterAssembly.adChapterTitle
                && ads.contains { $0.overlaps(startMs: ch.startMs, endMs: ch.endMs) }
        }
        XCTAssertTrue(overlapping.isEmpty, "content chapters must be split around ads, got \(overlapping)")
        // Timeline is sorted.
        XCTAssertEqual(chapters.map(\.startMs), chapters.map(\.startMs).sorted())
    }

    func testKeywordAdDetectorFlagsReadAndSkipsContent() async throws {
        // Tier-2 fallback detector: conservative keyword pass + D25 aggregation. A contiguous
        // sponsor read (three flagged lines bridged across ≤20s gaps) is caught; discussion about
        // a company without sponsor phrasing is not; an isolated one-liner (<8s) is dropped.
        var segs: [TranscriptSegment] = [
            TranscriptSegment(text: "welcome back to the show today we talk strategy", startMs: 0, endMs: 6_000),
            TranscriptSegment(text: "this episode is brought to you by acme security", startMs: 6_000, endMs: 12_000),
            TranscriptSegment(text: "acme watches your cloud so you don't have to", startMs: 12_000, endMs: 18_000),
            TranscriptSegment(text: "go to acme dot com slash pod and use code POD for twenty percent off", startMs: 18_000, endMs: 25_000),
            TranscriptSegment(text: "so back to the topic amazon's flywheel is fascinating", startMs: 25_000, endMs: 31_000),
        ]
        // Isolated single flagged line far from anything (should be dropped as a <8s isolate).
        segs.append(TranscriptSegment(text: "anyway they had a promo code back then funny story", startMs: 300_000, endMs: 305_000))
        let t = Transcript(episodeId: "kw", source: .asr, format: "asr", modelVersion: "x", segments: segs)

        let ads = try await KeywordAdDetector().detectAds(in: t)
        XCTAssertEqual(ads.count, 1, "one merged read, isolate dropped: \(ads)")
        XCTAssertEqual(ads[0].startMs, 6_000)
        XCTAssertEqual(ads[0].endMs, 25_000)
    }

    func testSemanticSearchFindsSegment() async throws {
        let segs = [
            TranscriptSegment(text: "we discussed compound interest and investing", startMs: 0, endMs: 1000),
            TranscriptSegment(text: "then we talked about baking sourdough bread", startMs: 1000, endMs: 2000),
        ]
        let t = Transcript(episodeId: "t", source: .asr, format: "asr", modelVersion: "x", segments: segs)
        let embedder = MockEmbedder()
        let vectors = try await embedder.embed(segs.map(\.text))
        let embeddings = zip(segs, vectors).map { SegmentEmbedding(segmentId: $0.id, vector: $1) }
        let search = SemanticSearch(transcript: t, embeddings: embeddings)
        let q = try await embedder.embed(["sourdough bread baking"])[0]
        let hits = search.topK(1, queryVector: q)
        XCTAssertEqual(hits.first?.segment.text, "then we talked about baking sourdough bread")
    }
}
