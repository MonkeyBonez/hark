import Foundation
import GRDB
import HarkCore
import AVFoundation
import BackgroundTasks
import UIKit

/// Transcript-first processing (user decision 2026-08-12): the episode is transcribed in 3-minute
/// chunks, **starting at the chunk under the playhead**, then forward to the end, then backfilling
/// the beginning (PRD §9.5 playhead-anchored ASR). Each chunk's segments are persisted the moment
/// the chunk finalizes — killing the app loses at most one chunk of work, and the next run resumes
/// from the coverage table ("one and done"). Snips and the live transcript light up within seconds
/// of pressing play.
///
/// The full LLM pipeline (digest + ad detection via the bundled MLX model) is PARKED, not deleted:
/// map/reduce over a whole transcript with the 1.7B crashes on-device (memory ceiling on the 6GB
/// floor device), and the current scope is snips + live transcript. `runFullPipeline` below is the
/// revival path — it needs chunk-scoped summarization or the Core ML/ANE port first.
///
/// TODO(cooldown): evict transcripts for episodes not listened to in N days (user request, later).
@MainActor
final class ProcessingService: ObservableObject {
    static let shared = ProcessingService()

    enum EpisodeState: Equatable {
        case idle, running(stage: String), done, failed(String)
    }

    @Published private(set) var states: [String: EpisodeState] = [:]
    /// episodeId → fraction of the episode transcribed (0…1); present only while a run is active.
    @Published private(set) var transcriptionProgress: [String: Double] = [:]
    /// Bumped every time a chunk of transcript is persisted or a snip is enriched — views re-read
    /// on change.
    @Published private(set) var transcriptVersion = 0
    /// Snip ids currently being titled by the LLM (drives the "Naming…" indicator).
    @Published private(set) var enrichingSnips: Set<String> = []

    private let db = AppDatabase.shared
    private var queue: [Episode] = []
    private var processing = false
    private var enriching = false
    /// Per-session retry cap so a persistently-failing snip doesn't reload the model forever.
    private var enrichAttempts: [String: Int] = [:]

    /// 3-minute windows: ~6s of ASR each at ~30x realtime, so the playhead's text arrives fast.
    static let chunkMs = 180_000

    func state(for episodeId: String) -> EpisodeState { states[episodeId] ?? .idle }

    // MARK: Transcription (the active path)

    /// Ensure this episode's transcript exists/completes. No-op while a run is active; already-
    /// covered chunks are skipped, so this is safe to call on every play.
    func transcribe(_ episode: Episode) {
        guard DownloadManager.localURL(for: episode) != nil else { return }
        if case .running = state(for: episode.id) { return }
        states[episode.id] = .running(stage: "queued")
        queue.append(episode)
        drainQueue()
    }

    /// Wipe this episode's transcript and coverage, then redo from scratch.
    func retranscribe(_ episode: Episode) {
        if case .running = state(for: episode.id) { return }
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcriptSegment WHERE episodeId = ?", arguments: [episode.id])
            try db.execute(sql: "DELETE FROM transcriptChunk WHERE episodeId = ?", arguments: [episode.id])
        }
        transcriptVersion += 1
        transcribe(episode)
    }

    private func drainQueue() {
        guard !processing, let episode = queue.first else { return }
        queue.removeFirst()
        processing = true
        Task {
            await run(episode)
            processing = false
            drainQueue()
        }
    }

    private func run(_ episode: Episode) async {
        guard let audioURL = DownloadManager.localURL(for: episode) else { return }
        // Keep the device awake while transcribing — a screen-sleep suspension stalls the run.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            states[episode.id] = .running(stage: "transcribing")
            try await setStatus(episode.id, stage: "transcript", status: "running", note: nil)

            let chunker = try await AudioChunkTranscriber.make(audioURL: audioURL, chunkMs: Self.chunkMs)
            let total = chunker.chunkCount
            var covered = try await coveredChunks(episode.id)
            transcriptionProgress[episode.id] = Double(covered.count) / Double(total)

            while covered.count < total {
                let idx = nextChunk(covered: covered, total: total, episodeId: episode.id)
                let base = Double(covered.count) / Double(total)
                let span = 1.0 / Double(total)
                let episodeId = episode.id
                let asr = SpeechTranscriberASR(onProgress: { fraction in
                    Task { @MainActor in
                        ProcessingService.shared.noteTranscription(base + fraction * span, for: episodeId)
                    }
                })
                try await asr.load()
                let segments = try await chunker.transcribe(chunk: idx, using: asr)
                try await persistChunk(episodeId, chunkIdx: idx, segments: segments)
                covered.insert(idx)
                transcriptVersion += 1
                transcriptionProgress[episodeId] = Double(covered.count) / Double(total)
                // Fresh text may now cover a snip captured before its words were transcribed.
                enrichPendingSnips()
            }

            try await setStatus(episode.id, stage: "transcript", status: "done", note: "\(total) chunks")
            states[episode.id] = .done
        } catch {
            states[episode.id] = .failed("\(error)")
            try? await setStatus(episode.id, stage: "transcript", status: "failed", note: "\(error)")
        }
        transcriptionProgress[episode.id] = nil
    }

    /// Chunk priority: the chunk under the playhead first (when this episode is the one playing),
    /// then the nearest uncovered chunk after it, then backfill from the start. Re-evaluated every
    /// chunk, so seeking ahead redirects the transcriber within one chunk (~6s).
    private func nextChunk(covered: Set<Int>, total: Int, episodeId: String) -> Int {
        var playheadChunk = 0
        if PlayerEngine.shared.currentEpisode?.id == episodeId {
            playheadChunk = min(total - 1, max(0, Int(PlayerEngine.shared.currentTime * 1000) / Self.chunkMs))
        }
        if let ahead = (playheadChunk..<total).first(where: { !covered.contains($0) }) { return ahead }
        return (0..<total).first(where: { !covered.contains($0) }) ?? 0
    }

    /// ASR progress ticks arrive from the collector task; publish whole-percent changes only so a
    /// 3-hour episode doesn't re-render every row several times a second.
    private func noteTranscription(_ fraction: Double, for episodeId: String) {
        guard case .running = state(for: episodeId) else { return }
        if Int(fraction * 100) != Int((transcriptionProgress[episodeId] ?? -1) * 100) {
            transcriptionProgress[episodeId] = fraction
        }
    }

    private func coveredChunks(_ episodeId: String) async throws -> Set<Int> {
        try await db.dbQueue.read { db in
            Set(try Int.fetchAll(db, sql: "SELECT chunkIdx FROM transcriptChunk WHERE episodeId = ?",
                                 arguments: [episodeId]))
        }
    }

    /// One transaction per chunk: replace that window's segments, mark the chunk covered. This is
    /// the "one and done" guarantee — a kill loses at most the in-flight chunk.
    private func persistChunk(_ episodeId: String, chunkIdx: Int, segments: [TranscriptSegment]) async throws {
        let windowStart = chunkIdx * Self.chunkMs
        let windowEnd = windowStart + Self.chunkMs
        try await db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcriptSegment WHERE episodeId = ? AND startMs >= ? AND startMs < ?",
                           arguments: [episodeId, windowStart, windowEnd])
            for seg in segments {
                try db.execute(sql: """
                    INSERT INTO transcriptSegment (id, episodeId, idx, text, startMs, endMs, speaker)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [seg.id.uuidString, episodeId, seg.startMs, seg.text,
                                     seg.startMs, seg.endMs, seg.speaker])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO transcriptChunk (episodeId, chunkIdx) VALUES (?, ?)",
                           arguments: [episodeId, chunkIdx])
        }
    }

    private func setStatus(_ episodeId: String, stage: String, status: String, note: String?) async throws {
        try await db.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO artifactStatus (episodeId, stage, status, modelVersion, note, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(episodeId, stage) DO UPDATE SET status = excluded.status,
                    note = excluded.note, updatedAt = excluded.updatedAt
                """, arguments: [episodeId, stage, status, "p3", note, Date()])
        }
    }

    // MARK: Reads for the UI

    func hasArtifacts(_ episodeId: String) -> Bool {
        (try? db.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter WHERE episodeId = ?", arguments: [episodeId]) ?? 0
        }).map { $0 > 0 } ?? false
    }

    func chapters(for episodeId: String) -> [(title: String, startMs: Int, endMs: Int)] {
        (try? db.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT title, startMs, endMs FROM chapter WHERE episodeId = ? ORDER BY startMs",
                             arguments: [episodeId])
                .map { ($0["title"] as String, $0["startMs"] as Int, $0["endMs"] as Int) }
        }) ?? []
    }

    func summary(for episodeId: String) -> (tldr: String, takeaways: [String])? {
        try? db.dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT tldr, takeawaysJSON FROM episodeSummary WHERE episodeId = ?",
                                             arguments: [episodeId]) else { return nil }
            let takeaways = (try? JSONDecoder().decode([String].self,
                                                       from: Data((row["takeawaysJSON"] as String).utf8))) ?? []
            return (row["tldr"] as String, takeaways)
        }
    }

    /// Ordered transcript lines for the follow-along view and snip-text derivation.
    func segments(for episodeId: String) -> [TranscriptLine] {
        (try? db.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, text, startMs, endMs, speaker FROM transcriptSegment
                WHERE episodeId = ? ORDER BY startMs
                """, arguments: [episodeId])
                .map { TranscriptLine(id: $0["id"], text: $0["text"],
                                      startMs: $0["startMs"], endMs: $0["endMs"], speaker: $0["speaker"]) }
        }) ?? []
    }

    /// Cheap existence check: any transcript text at all for this episode.
    func hasTranscript(for episodeId: String) -> Bool {
        (try? db.dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM transcriptSegment WHERE episodeId = ?)",
                              arguments: [episodeId]) ?? false
        }) ?? false
    }

    // MARK: Snip enrichment (on-device LLM, small prompts only)

    /// Title/categorize/bullet every captured snip whose transcript text exists (PRD §8.4 — snips
    /// jump the queue). This is the ONLY live LLM path: a 30-second excerpt is a tiny prompt, safe
    /// on-device, unlike the parked whole-episode digest. Triggered on capture, after every
    /// persisted chunk, and when the Snips tab appears.
    func enrichPendingSnips() {
        guard !enriching else { return }
        enriching = true
        Task {
            await runEnrichment()
            enriching = false
        }
    }

    private func runEnrichment() async {
        var model: MLXIntelligence?
        defer { if let model { Task { await model.unload() } } }

        // Re-scan after each batch so a snip captured mid-run is picked up while the model is warm.
        while true {
            let jobs = pendingEnrichmentJobs()
            guard !jobs.isEmpty else { break }

            if model == nil {
                let m = MLXIntelligence(modelId: "mlx-community/Qwen3-1.7B-4bit",
                                        approxResidentBytes: 1_300 * 1_000_000)
                do { try await m.load() } catch {
                    for (snip, _) in jobs { enrichAttempts[snip.id, default: 0] += 1 }
                    return
                }
                model = m
            }

            for (snip, excerpt) in jobs {
                enrichingSnips.insert(snip.id)
                enrichAttempts[snip.id, default: 0] += 1
                do {
                    let enrichment = try await model!.enrichSnip(SnipEnrichmentRequest(
                        episodeId: snip.episodeId, excerpt: excerpt,
                        startMs: snip.startMs, endMs: snip.endMs))
                    var updated = snip
                    updated.title = enrichment.title
                    updated.category = enrichment.category.rawValue
                    updated.takeawaysJSON = String(
                        data: (try? JSONEncoder().encode(enrichment.bullets)) ?? Data("[]".utf8),
                        encoding: .utf8)
                    updated.state = "enriched"
                    try? await db.dbQueue.write { try updated.save($0) }
                    transcriptVersion += 1
                } catch {
                    // Leave it "captured"; the attempt cap retries once more on a later trigger.
                }
                enrichingSnips.remove(snip.id)
            }
        }
    }

    /// Captured snips (no title yet, under the retry cap) whose window has transcript text.
    private func pendingEnrichmentJobs() -> [(Snip, String)] {
        let pending: [Snip] = (try? db.dbQueue.read { db in
            try Snip.filter(Column("title") == nil).order(Column("createdAt").desc).fetchAll(db)
        }) ?? []
        var jobs: [(Snip, String)] = []
        for snip in pending where (enrichAttempts[snip.id] ?? 0) < 2 {
            let text = segments(for: snip.episodeId)
                .filter { $0.endMs > snip.startMs && $0.startMs < snip.endMs }
                .map(\.text).joined(separator: " ")
            if !text.isEmpty { jobs.append((snip, text)) }
        }
        return jobs
    }

    // MARK: - PARKED: full AI pipeline (digest + ad detection)
    //
    // Unreferenced but kept compiling so the revival is a one-line change. Running the whole-
    // transcript map/reduce with the bundled 1.7B MLX model crashes on-device (jetsam on long
    // episodes); do NOT re-enable until summarization is chunk-scoped or the Core ML/ANE port
    // lands. The engine set and persistence below are the D38 single-model architecture.

    private func runFullPipeline(_ episode: Episode) async {
        guard let audioURL = DownloadManager.localURL(for: episode) else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            states[episode.id] = .running(stage: "transcribing")
            try await setStatus(episode.id, stage: "pipeline", status: "running", note: nil)

            let engines = try makeEngineSet(episodeId: episode.id)
            let orchestrator = PipelineOrchestrator(engines: engines)
            let duration = episode.durationSeconds ?? 0
            let result = try await orchestrator.process(episodeId: episode.id, audioURL: audioURL,
                                                        audioSeconds: duration)

            states[episode.id] = .running(stage: "saving")
            try await persist(result, episodeId: episode.id)
            try await setStatus(episode.id, stage: "pipeline", status: "done",
                                note: result.record.stages.map(\.stage).joined(separator: ","))
            states[episode.id] = .done
        } catch {
            states[episode.id] = .failed("\(error)")
            try? await setStatus(episode.id, stage: "pipeline", status: "failed", note: "\(error)")
        }
        transcriptionProgress[episode.id] = nil
    }

    private func makeEngineSet(episodeId: String) throws -> EngineSet {
        let intelligence = MLXIntelligence(modelId: "mlx-community/Qwen3-1.7B-4bit",
                                           approxResidentBytes: 1_300 * 1_000_000)
        let asr = SpeechTranscriberASR(onProgress: { fraction in
            Task { @MainActor in ProcessingService.shared.noteTranscription(fraction, for: episodeId) }
        })
        return EngineSet(label: "on-device-mlx",
                         asr: asr,
                         diarizer: nil,
                         embedder: try NLContextualEmbeddingEngine(),
                         intelligence: intelligence,
                         adDetector: MLXAdDetector(backing: intelligence))
    }

    private func persist(_ result: PipelineResult, episodeId: String) async throws {
        let artifacts = result.artifacts
        try await db.dbQueue.write { db in
            for table in ["transcriptSegment", "adRange", "chapter", "keyMoment"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE episodeId = ?", arguments: [episodeId])
            }
            try db.execute(sql: "DELETE FROM episodeSummary WHERE episodeId = ?", arguments: [episodeId])

            for (idx, seg) in artifacts.transcript.segments.enumerated() {
                try db.execute(sql: """
                    INSERT INTO transcriptSegment (id, episodeId, idx, text, startMs, endMs, speaker)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [seg.id.uuidString, episodeId, idx, seg.text, seg.startMs, seg.endMs, seg.speaker])
            }
            for ad in artifacts.ads {
                try db.execute(sql: """
                    INSERT INTO adRange (id, episodeId, startMs, endMs, confidence, userVerdict)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, episodeId, ad.startMs, ad.endMs, ad.confidence, ad.userVerdict.rawValue])
            }
            if let digest = artifacts.digest {
                for ch in digest.chapters {
                    try db.execute(sql: """
                        INSERT INTO chapter (id, episodeId, title, startMs, endMs) VALUES (?, ?, ?, ?, ?)
                        """, arguments: [UUID().uuidString, episodeId, ch.title, ch.startMs, ch.endMs])
                }
                for km in digest.keyMoments {
                    try db.execute(sql: """
                        INSERT INTO keyMoment (id, episodeId, title, startMs, endMs) VALUES (?, ?, ?, ?, ?)
                        """, arguments: [UUID().uuidString, episodeId, km.title, km.startMs, km.endMs])
                }
                let takeaways = String(data: try JSONEncoder().encode(digest.summary.takeaways), encoding: .utf8) ?? "[]"
                try db.execute(sql: """
                    INSERT INTO episodeSummary (episodeId, tldr, takeawaysJSON) VALUES (?, ?, ?)
                    """, arguments: [episodeId, digest.summary.tldr, takeaways])
            }
        }
    }
}

// MARK: - Chunked audio transcription

/// Cuts a downloaded episode into fixed windows, decodes each to a temp PCM file, batch-transcribes
/// it with SpeechTranscriberASR, and offsets the timestamps back onto the episode timeline. The
/// async methods are nonisolated, so decode + ASR run off the main actor.
struct AudioChunkTranscriber: Sendable {
    let audioURL: URL
    let chunkMs: Int
    let durationMs: Int

    var chunkCount: Int { max(1, (durationMs + chunkMs - 1) / chunkMs) }

    /// Async factory: opening an AVAudioFile on a long VBR mp3 can scan the file — keep it off main.
    static func make(audioURL: URL, chunkMs: Int) async throws -> AudioChunkTranscriber {
        let file = try AVAudioFile(forReading: audioURL)
        let seconds = file.processingFormat.sampleRate > 0
            ? Double(file.length) / file.processingFormat.sampleRate : 0
        return AudioChunkTranscriber(audioURL: audioURL, chunkMs: chunkMs,
                                     durationMs: max(1, Int(seconds * 1000)))
    }

    func transcribe(chunk idx: Int, using asr: SpeechTranscriberASR) async throws -> [TranscriptSegment] {
        let tmp = try extractChunk(idx)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let transcript = try await asr.transcribe(audioURL: tmp)
        let offset = idx * chunkMs
        return transcript.segments.map {
            TranscriptSegment(text: $0.text, startMs: $0.startMs + offset, endMs: $0.endMs + offset)
        }
    }

    /// Decode [idx·chunkMs, (idx+1)·chunkMs) to a temp CAF (PCM) that SpeechTranscriber can read.
    private func extractChunk(_ idx: Int) throws -> URL {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let startFrame = AVAudioFramePosition(Double(idx) * Double(chunkMs) / 1000 * sampleRate)
        let endFrame = min(file.length, AVAudioFramePosition(Double(idx + 1) * Double(chunkMs) / 1000 * sampleRate))
        file.framePosition = startFrame

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-chunk-\(UUID().uuidString).caf")
        let out = try AVAudioFile(forWriting: tmp, settings: format.settings)

        var remaining = AVAudioFrameCount(max(0, endFrame - startFrame))
        let capacity = AVAudioFrameCount(sampleRate)   // 1-second buffers
        while remaining > 0 {
            let count = min(capacity, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            try file.read(into: buffer, frameCount: count)
            if buffer.frameLength == 0 { break }
            try out.write(from: buffer)
            remaining -= buffer.frameLength
        }
        return tmp
    }
}
