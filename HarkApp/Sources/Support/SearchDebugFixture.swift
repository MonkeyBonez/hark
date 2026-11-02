#if DEBUG && targetEnvironment(simulator)
import AVFoundation
import Foundation
import GRDB

/// Opt-in simulator-only data. The words are authored test text, not an ASR result.
enum SearchDebugFixture {
    private enum FixtureError: Error { case audioFormat }

    /// Simulates an asset request that may finish after its caller is cancelled.
    static func delayOpeningIfRequested(stage: String) async {
        let env = ProcessInfo.processInfo.environment
        guard env["HARK_SEARCH_FIXTURE"] == "1",
              (env["HARK_SEARCH_DELAY_STAGE"] ?? "asset") == stage,
              let value = env["HARK_SEARCH_DELAY_MS"], let milliseconds = Int(value),
              (1...15_000).contains(milliseconds) else { return }
        let response = Task.detached {
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
        _ = await response.value
    }

    static func seed() throws {
        let filename = "hark-search-synthetic.wav"
        let audioURL = AppDatabase.audioDirectory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: audioURL.path) {
            try writeAudio(to: audioURL)
        }

        let feed = "https://synthetic.invalid/search-fixture"
        let podcast = Podcast(feedURL: feed, title: "Synthetic Fixture Podcast", author: nil,
                              artworkURL: nil, summary: nil, subscribedAt: Date(), adSkipMode: "ask")
        let playable = Episode(
            id: "search-fixture-episode", podcastFeedURL: feed, title: "Synthetic Search Episode",
            summary: nil, audioURL: "", publishedAt: Date(), durationSeconds: 90,
            downloadState: "downloaded", localFilename: filename, playbackPositionSeconds: 0,
            lastPlayedAt: nil, finished: false
        )
        let unavailable = Episode(
            id: "search-fixture-unavailable", podcastFeedURL: feed, title: "Unavailable Fixture Episode",
            summary: nil, audioURL: "", publishedAt: Date(), durationSeconds: 90,
            downloadState: "none", localFilename: nil, playbackPositionSeconds: 0,
            lastPlayedAt: nil, finished: false
        )
        let snip = Snip(
            id: "search-fixture-snip", episodeId: playable.id, startMs: 47_500, endMs: 60_000,
            createdAt: Date(), starred: false, state: "captured", title: "Lantern by the harbor",
            category: nil, takeawaysJSON: "[\"Synthetic fixture, not model output.\"]"
        )
        try AppDatabase.shared.dbQueue.write { db in
            try podcast.save(db)
            try playable.save(db)
            try unavailable.save(db)
            try snip.save(db)
            for segment in [
                ("search-fixture-intro", playable.id, 0, "A copper compass points toward a hidden valley.", 5_000, 12_000),
                ("search-fixture-lantern", playable.id, 1, "The violet lantern marks the quiet harbor.", 42_250, 58_000),
                ("search-fixture-missing", unavailable.id, 0, "Marigold audio is intentionally unavailable.", 12_000, 18_000),
            ] {
                try db.execute(sql: """
                    INSERT INTO transcriptSegment (id, episodeId, idx, text, startMs, endMs, speaker)
                    VALUES (?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(id) DO UPDATE SET episodeId = excluded.episodeId, idx = excluded.idx,
                        text = excluded.text, startMs = excluded.startMs, endMs = excluded.endMs
                    """, arguments: [segment.0, segment.1, segment.2, segment.3, segment.4, segment.5])
            }
            // The one synthetic chunk is already covered; playback must not invoke ASR.
            try db.execute(sql: """
                INSERT OR IGNORE INTO transcriptChunk (episodeId, chunkIdx) VALUES (?, 0)
                """, arguments: [playable.id])
        }
    }

    private static func writeAudio(to url: URL) throws {
        let sampleRate = 16_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)),
              let samples = buffer.floatChannelData?[0] else { throw FixtureError.audioFormat }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate) * 0.03)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<90 { try file.write(from: buffer) }
    }
}
#endif
