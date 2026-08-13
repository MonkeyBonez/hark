import Foundation

/// A complete, swappable set of engines — one row in the bake-off matrix.
public struct EngineSet: Sendable {
    public var label: String
    public var asr: SpeechToTextEngine
    public var diarizer: DiarizationEngine?
    public var embedder: EmbeddingEngine
    public var intelligence: EpisodeIntelligenceEngine
    public var adDetector: AdDetectionEngine

    public init(label: String, asr: SpeechToTextEngine, diarizer: DiarizationEngine? = nil,
                embedder: EmbeddingEngine, intelligence: EpisodeIntelligenceEngine, adDetector: AdDetectionEngine) {
        self.label = label; self.asr = asr; self.diarizer = diarizer
        self.embedder = embedder; self.intelligence = intelligence; self.adDetector = adDetector
    }
}

/// Everything the pipeline produces for one episode.
public struct PipelineArtifacts: Sendable {
    public var transcript: Transcript
    public var embeddings: [SegmentEmbedding]
    public var ads: [AdRange]
    public var digest: EpisodeDigest?      // nil if the LLM stage was degraded away
}

public struct PipelineResult: Sendable {
    public var record: EpisodeRunRecord
    public var artifacts: PipelineArtifacts
}

/// The chunked map-reduce orchestrator — the architectural spine of P0 (PRD §9.2, §9.5, §9.6).
///
/// Guarantees encoded here (not left to callers):
///  • **Single AI model resident at a time** — ASR is `unload()`ed before the LLM `load()`s.
///  • **Ad-exclusion contract** — the reduce stage only ever sees transcript minus detected ads,
///    and key moments are validated against ads.
///  • **Degrade-don't-die** — if the memory guard trips, the LLM stage is skipped and the run still
///    returns a transcript + embeddings (playback/search survive); the audio is never dropped.
///  • Every stage is timed and its resident-set estimated for the model-decision-record.
public struct PipelineOrchestrator: Sendable {
    public let engines: EngineSet
    public let memoryGuard: MemoryGuard

    public init(engines: EngineSet, memoryGuard: MemoryGuard = MemoryGuard()) {
        self.engines = engines
        self.memoryGuard = memoryGuard
    }

    /// Process one episode end-to-end. If `officialTranscript` is supplied (and passed the quality
    /// gate upstream) the ASR stage is skipped, matching the Podcasting 2.0 fast path (PRD §6).
    public func process(episodeId: String, audioURL: URL, audioSeconds: Double,
                        officialTranscript: Transcript? = nil) async throws -> PipelineResult {
        var stages: [StageMetric] = []
        var peakResident = 0
        func notePeak(_ bytes: Int) { peakResident = max(peakResident, bytes) }

        // 1. TRANSCRIBE (or use official). ASR is loaded and then fully unloaded before the LLM.
        let transcript: Transcript
        if let official = officialTranscript {
            transcript = official
            stages.append(StageMetric(stage: "transcribe", engineId: "official-\(official.format)",
                                      wallClockSeconds: 0, realTimeFactor: nil, note: "official transcript, ASR skipped"))
        } else {
            try await engines.asr.load()
            notePeak(engines.asr.approxResidentBytes)
            let sw = Stopwatch()
            transcript = try await engines.asr.transcribe(audioURL: audioURL)
            let secs = sw.seconds()
            await engines.asr.unload()
            stages.append(StageMetric(stage: "transcribe", engineId: engines.asr.identifier,
                                      wallClockSeconds: secs,
                                      realTimeFactor: secs > 0 ? audioSeconds / secs : nil,
                                      peakResidentBytes: engines.asr.approxResidentBytes))
        }

        // 2. DIARIZE (optional). Runs on the official path too (SRT/VTT lack speakers).
        var workingTranscript = transcript
        if let diarizer = engines.diarizer {
            try await diarizer.load()
            notePeak(diarizer.approxResidentBytes)
            let sw = Stopwatch()
            workingTranscript = try await diarizer.diarize(audioURL: audioURL, transcript: transcript)
            let secs = sw.seconds()
            await diarizer.unload()
            stages.append(StageMetric(stage: "diarize", engineId: diarizer.identifier,
                                      wallClockSeconds: secs, peakResidentBytes: diarizer.approxResidentBytes))
        }

        // 3. LLM STAGES + EMBEDDINGS. Check the memory budget before loading the LLM.
        var embeddings: [SegmentEmbedding] = []
        var ads: [AdRange] = []
        var digest: EpisodeDigest? = nil
        var degraded = false

        switch memoryGuard.decision(forStageNeeding: engines.intelligence.approxResidentBytes + engines.embedder.approxResidentBytes) {
        case .degrade(let reason):
            // Degrade-don't-die: keep transcript (playback/karaoke) but skip AI enrichment this pass.
            degraded = true
            stages.append(StageMetric(stage: "llm", engineId: engines.intelligence.identifier,
                                      wallClockSeconds: 0, degraded: true, note: "degraded: \(reason)"))
            // Embeddings are cheap; still try them so find-a-moment works.
            embeddings = try await runEmbeddings(workingTranscript, stages: &stages, notePeak: notePeak)

        case .proceed:
            // Degrade-don't-die applies to engine UNAVAILABILITY, not just memory pressure: on a
            // device without Apple Intelligence (or a model not yet ready), `load()` on the FM
            // engines throws. That must degrade the STAGE — never fail the run and discard the
            // transcript ASR already paid minutes for. Tier-2 bundled fallback is deferred (D31);
            // until it ships, unavailability = transcript + embeddings + keyword search, no digest.

            // Embeddings run in PARALLEL with everything else (they only need the transcript, ads
            // included — find-a-moment should be able to jump to any spoken moment).
            var embedTask: Task<[SegmentEmbedding], Error>? = nil
            var embedderLoaded = false
            do {
                try await engines.embedder.load()
                embedderLoaded = true
                notePeak(engines.embedder.approxResidentBytes)
                let frozenTranscript = workingTranscript   // immutable snapshot for concurrent capture
                let orchestrator = self
                embedTask = Task { try await orchestrator.embedInline(frozenTranscript) }
            } catch {
                stages.append(StageMetric(stage: "embed", engineId: engines.embedder.identifier,
                                          wallClockSeconds: 0, degraded: true,
                                          note: "embedder unavailable — skipped: \(error)"))
            }

            // 3a. AD DETECTION FIRST — segment-granular, BEFORE the model sees any text (E7 fix).
            let adSW = Stopwatch()
            do {
                try await engines.adDetector.load()
                notePeak(engines.adDetector.approxResidentBytes)
                ads = try await engines.adDetector.detectAds(in: workingTranscript)
                await engines.adDetector.unload()
                stages.append(StageMetric(stage: "ad-detect", engineId: engines.adDetector.identifier,
                                          wallClockSeconds: adSW.seconds(),
                                          note: String(format: "%.0f%% of episode", AdExclusion.adFraction(workingTranscript, ads: ads) * 100)))
            } catch {
                ads = []
                stages.append(StageMetric(stage: "ad-detect", engineId: engines.adDetector.identifier,
                                          wallClockSeconds: adSW.seconds(), degraded: true,
                                          note: "unavailable — skipped: \(error)"))
            }

            // 3b. Remove ad segments BEFORE chunking so the LLM never summarizes a sponsor read.
            let adFreeTranscript = AdExclusion.adFreeTranscript(workingTranscript, ads: ads)

            var intelligenceLoaded = false
            do {
                try await engines.intelligence.load()
                intelligenceLoaded = true
                notePeak(engines.intelligence.approxResidentBytes + engines.embedder.approxResidentBytes)
            } catch {
                degraded = true
                stages.append(StageMetric(stage: "llm", engineId: engines.intelligence.identifier,
                                          wallClockSeconds: 0, degraded: true,
                                          note: "intelligence unavailable — digest skipped: \(error)"))
            }

            if intelligenceLoaded {
            // 3c. MAP over token-bounded windows of the AD-FREE transcript.
            // Each window call is independently guarded (E11 fix): a real-world model REFUSAL
            // (confirmed live — Foundation Models rejected a real biographical episode as
            // "may contain sensitive content") must not abort the whole episode. A window that
            // fails is simply skipped, mirroring the resilience FoundationModelsAdDetector already
            // had per-batch (D15) — this closes the gap where map/reduce had no equivalent guard.
            let chunker = Chunker.forContextLimit(engines.intelligence.contextTokenLimit)
            let windows = chunker.windows(for: adFreeTranscript)
            let mapSW = Stopwatch()
            var notes: [WindowNotes] = []
            var refused = 0, recovered = 0, dropped = 0
            var lastMapError: String? = nil
            for window in windows {
                do {
                    notes.append(try await engines.intelligence.mapWindow(window))
                } catch {
                    // Retry-once backstop (E12): refusals proved NON-deterministic across identical
                    // runs, so one fresh retry recovers real windows cheaply. Second failure → skip
                    // (degrade-don't-die). Bound: +1 call per failed window.
                    refused += 1
                    do {
                        notes.append(try await engines.intelligence.mapWindow(window))
                        recovered += 1
                    } catch {
                        dropped += 1
                        lastMapError = String(describing: error)
                    }
                }
            }
            var mapNote = "\(windows.count) ad-free windows @ ≤\(chunker.targetTokens) tok"
            if refused > 0 {
                mapNote += " (refused: \(refused), recovered-on-retry: \(recovered), dropped: \(dropped)"
                if let e = lastMapError { mapNote += "; last: \(e)" }
                mapNote += ")"
            }
            stages.append(StageMetric(stage: "llm.map", engineId: engines.intelligence.identifier,
                                      wallClockSeconds: mapSW.seconds(), note: mapNote))

            // 3d. REDUCE over all notes (ad-free by construction); validate key moments against ads.
            let redSW = Stopwatch()
            if notes.isEmpty {
                // Entire episode classified as ad, or every window failed — degrade rather than hallucinate.
                stages.append(StageMetric(stage: "llm.reduce", engineId: engines.intelligence.identifier,
                                          wallClockSeconds: 0, degraded: true, note: "no ad-free content to summarize"))
            } else {
                // Retry-once here too (E12), then extractive fallback.
                func attemptReduce() async throws -> EpisodeDigest {
                    try await engines.intelligence.reduce(notes: notes, adFreeText: adFreeTranscript.fullText)
                }
                do {
                    var d: EpisodeDigest
                    var retried = false
                    do {
                        d = try await attemptReduce()
                    } catch {
                        retried = true
                        d = try await attemptReduce()
                    }
                    d.keyMoments = AdExclusion.validate(keyMoments: d.keyMoments, against: ads)
                    digest = d
                    stages.append(StageMetric(stage: "llm.reduce", engineId: engines.intelligence.identifier,
                                              wallClockSeconds: redSW.seconds(),
                                              note: retried ? "recovered on retry" : nil))
                } catch {
                    // Reduce refused/failed twice: fall back to an EXTRACTIVE digest built directly
                    // from the map notes already in hand — no further model call, so it can't also
                    // fail. This is the "extractive-summary fallback" the PRD's risk table (§13)
                    // already names as the mitigation for LLM-stage failure.
                    digest = Self.extractiveFallbackDigest(from: notes)
                    stages.append(StageMetric(stage: "llm.reduce", engineId: engines.intelligence.identifier,
                                              wallClockSeconds: redSW.seconds(), degraded: true,
                                              note: "reduce refused/failed twice (\(String(describing: error))) — extractive fallback used"))
                }
            }

            // 3e. CHAPTER TIMELINE — merge detected ads into the chapter list as visible, labeled
            // "Sponsor break" chapters (PRD §8.11): the listener sees the break and skips it
            // themselves. Deterministic, no model call, applies to the extractive fallback too.
            if var d = digest {
                d.chapters = ChapterAssembly.timeline(content: d.chapters, ads: ads)
                digest = d
            }
            }   // if intelligenceLoaded

            if let embedTask {
                do {
                    embeddings = try await embedTask.value
                    stages.append(StageMetric(stage: "embed", engineId: engines.embedder.identifier,
                                              wallClockSeconds: 0, note: "\(embeddings.count) segment vectors (parallel)"))
                } catch {
                    stages.append(StageMetric(stage: "embed", engineId: engines.embedder.identifier,
                                              wallClockSeconds: 0, degraded: true,
                                              note: "embedding failed: \(error)"))
                }
            }

            if intelligenceLoaded { await engines.intelligence.unload() }
            if embedderLoaded { await engines.embedder.unload() }
        }

        let quality = QualityScore(adFractionDetected: AdExclusion.adFraction(workingTranscript, ads: ads))
        let record = EpisodeRunRecord(episodeId: episodeId, audioSeconds: audioSeconds, stages: stages,
                                      quality: quality, digest: digest, peakResidentBytesOverall: peakResident)
        let artifacts = PipelineArtifacts(transcript: workingTranscript, embeddings: embeddings, ads: ads, digest: digest)
        _ = degraded
        return PipelineResult(record: record, artifacts: artifacts)
    }

    /// Builds a digest with NO further model call, from map notes already in hand — used when the
    /// reduce call itself refuses/fails (E11). Deliberately plain: topic labels become chapters
    /// (already time-anchored from the map stage, so no anchoring guesswork), salient points become
    /// takeaways, and the TL;DR is a terse join rather than a synthesized sentence. Key moments are
    /// left empty (choosing highlights is exactly the judgment call the failed model call would have
    /// made — better to omit than to fake it).
    static func extractiveFallbackDigest(from notes: [WindowNotes]) -> EpisodeDigest {
        let chapters = notes.map { Chapter(title: $0.topicLabel, startMs: $0.startMs, endMs: $0.endMs) }
        let takeaways = Array(notes.flatMap(\.salientPoints).prefix(8))
        let tldr = notes.map(\.topicLabel).joined(separator: "; ")
        return EpisodeDigest(summary: EpisodeSummary(tldr: tldr, takeaways: takeaways),
                             keyMoments: [], chapters: chapters)
    }

    // Embeddings helper used on the degraded path (embedder loaded/unloaded on its own).
    private func runEmbeddings(_ transcript: Transcript, stages: inout [StageMetric],
                               notePeak: (Int) -> Void) async throws -> [SegmentEmbedding] {
        try await engines.embedder.load()
        notePeak(engines.embedder.approxResidentBytes)
        let sw = Stopwatch()
        let result = try await embedInline(transcript)
        stages.append(StageMetric(stage: "embed", engineId: engines.embedder.identifier,
                                  wallClockSeconds: sw.seconds(), note: "\(result.count) vectors (degraded path)"))
        await engines.embedder.unload()
        return result
    }

    private func embedInline(_ transcript: Transcript) async throws -> [SegmentEmbedding] {
        let vectors = try await engines.embedder.embed(transcript.segments.map(\.text))
        return zip(transcript.segments, vectors).map { SegmentEmbedding(segmentId: $0.id, vector: $1) }
    }
}
