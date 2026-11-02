import Foundation
import GRDB
import Testing
@testable import Hark

@Suite("Local moment search")
struct MomentSearchTests {
    @Test func migrationBackfillsExistingSnipsAndPersistsAcrossReopen() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("HarkSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("search.sqlite").path

        do {
            let queue = try DatabaseQueue(path: path)
            try AppDatabase.migrator.migrate(queue, upTo: "v4-snip-enrichment")
            try queue.write { db in try insertFixture(db) }
            try AppDatabase.migrator.migrate(queue)
            let result = try search("lantern", in: queue)
            #expect(result.snips.map(\.recordID) == ["snip-1"])
            #expect(result.transcript.map(\.recordID) == ["line-1"])
        }

        let reopened = try DatabaseQueue(path: path)
        try AppDatabase.migrator.migrate(reopened)
        let titleResult = try search("lighthouse", in: reopened)
        #expect(titleResult.snips.map(\.recordID) == ["snip-1"])
        #expect(titleResult.transcript.isEmpty)
        let transcriptResult = try search("violet", in: reopened)
        #expect(transcriptResult.snips.map(\.startMs) == [47_500])
        #expect(transcriptResult.transcript.map(\.startMs) == [42_250])
    }

    @Test func mutationsAndDestinationUseCurrentStoredTimes() throws {
        let queue = try database()
        try queue.write { db in try insertFixture(db) }
        let initial = try search("violet", in: queue)
        let line = try #require(initial.transcript.first)
        let snip = try #require(initial.snips.first)
        let lineDestination = try queue.read { try MomentSearch.destination(for: line, in: $0) }
        let snipDestination = try queue.read { try MomentSearch.destination(for: snip, in: $0) }
        #expect(lineDestination?.episode.id == "episode-1")
        #expect(lineDestination?.startMs == 42_250)
        #expect(lineDestination?.snip == nil)
        #expect(snipDestination?.episode.id == "episode-1")
        #expect(snipDestination?.snip?.id == "snip-1")
        #expect(snipDestination?.startMs == 47_500)

        try queue.write { db in
            try db.execute(sql: "UPDATE snip SET takeawaysJSON = ? WHERE id = ?",
                           arguments: ["[\"A cobalt compass\"]", "snip-1"])
        }
        #expect(try search("cobalt", in: queue).snips.map(\.recordID) == ["snip-1"])
        #expect(try search("takeaway", in: queue).snips.isEmpty)

        try queue.write { db in
            try db.execute(sql: "UPDATE snip SET startMs = ?, title = ? WHERE id = ?",
                           arguments: [52_000, "Amber notebook", "snip-1"])
            try db.execute(sql: "UPDATE transcriptSegment SET startMs = ?, text = ? WHERE id = ?",
                           arguments: [43_000, "The amber lantern marks the harbor.", "line-1"])
        }
        #expect(try search("violet", in: queue).isEmpty)
        #expect(try search("lighthouse", in: queue).isEmpty)
        let amber = try search("amber", in: queue)
        #expect(amber.snips.map(\.recordID) == ["snip-1"])
        #expect(amber.transcript.map(\.startMs) == [43_000])
        #expect(try queue.read { try MomentSearch.destination(for: snip, in: $0)?.startMs } == 52_000)
        #expect(try queue.read { try MomentSearch.destination(for: line, in: $0)?.startMs } == 43_000)

        try queue.write { db in
            try db.execute(sql: "DELETE FROM snip WHERE id = ?", arguments: ["snip-1"])
            try db.execute(sql: "DELETE FROM transcriptSegment WHERE id = ?", arguments: ["line-1"])
        }
        #expect(try search("amber", in: queue).isEmpty)
        #expect(try queue.read { try MomentSearch.destination(for: snip, in: $0) } == nil)
        #expect(try queue.read { try MomentSearch.destination(for: line, in: $0) } == nil)
    }

    @Test func safeQueriesAndOverlapBoundaries() throws {
        let queue = try database()
        try queue.write { db in
            try insertFixture(db)
            try db.execute(sql: """
                INSERT INTO transcriptSegment (id, episodeId, idx, text, startMs, endMs)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: ["before", "episode-1", 2, "café before", 40_000, 47_500])
            try db.execute(sql: """
                INSERT INTO transcriptSegment (id, episodeId, idx, text, startMs, endMs)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: ["after", "episode-1", 3, "café after", 60_000, 65_000])
        }
        #expect(MomentSearch.pattern(for: "")?.rawPattern == nil)
        #expect(MomentSearch.pattern(for: "?! …")?.rawPattern == nil)
        #expect(MomentSearch.pattern(for: String(repeating: "a", count: 201))?.rawPattern == nil)
        #expect(try search("VIOLET harbor", in: queue).transcript.map(\.recordID) == ["line-1"])
        #expect(try search("violet copper", in: queue).isEmpty)
        let boundary = try search("CAFE", in: queue)
        #expect(boundary.transcript.map(\.recordID) == ["before", "after"])
        #expect(boundary.snips.isEmpty)
        _ = try search(#"" OR * snip_ft MATCH --"#, in: queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM episode") } == 1)
    }

    @Test func resultsAreBoundedAndOrderedByStoredTime() throws {
        let queue = try database()
        try queue.write { db in
            try insertFixture(db)
            for index in 0..<55 {
                try db.execute(sql: """
                    INSERT INTO transcriptSegment (id, episodeId, idx, text, startMs, endMs)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: ["beacon-\(index)", "episode-1", index + 10, "A distant beacon.",
                                     index * 1_000, index * 1_000 + 900])
            }
        }
        let results = try search("beacon", in: queue)
        #expect(results.transcript.count == 50)
        #expect(results.transcript.first?.startMs == 0)
        #expect(results.transcript.last?.startMs == 49_000)
    }

    @Test(.timeLimit(.minutes(1))) func observationRefreshesOnInsertUpdateAndDelete() async throws {
        let queue = try database()
        try await queue.write { db in try insertFixture(db) }
        let pattern = try #require(MomentSearch.pattern(for: "quartz"))
        var iterator = MomentSearch.observation(for: pattern).values(in: queue).makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial?.isEmpty == true)

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transcriptSegment (id, episodeId, idx, text, startMs, endMs)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: ["live", "episode-1", 4, "A quartz marker.", 48_000, 49_000])
        }
        let inserted = try await iterator.next()
        #expect(inserted?.transcript.map(\.recordID) == ["live"])
        #expect(inserted?.snips.map(\.recordID) == ["snip-1"])

        try await queue.write { db in
            try db.execute(sql: "UPDATE transcriptSegment SET text = ? WHERE id = ?",
                           arguments: ["A different marker.", "live"])
        }
        let updated = try await iterator.next()
        #expect(updated?.isEmpty == true)

        try await queue.write { db in
            try db.execute(sql: "UPDATE snip SET title = ? WHERE id = ?",
                           arguments: ["Quartz notes", "snip-1"])
        }
        let renamed = try await iterator.next()
        #expect(renamed?.snips.map(\.recordID) == ["snip-1"])
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM snip WHERE id = ?", arguments: ["snip-1"])
        }
        let deleted = try await iterator.next()
        #expect(deleted?.isEmpty == true)
    }

    @Test func playbackSourceRejectsMissingOrUnsupportedAudio() throws {
        let local = URL(fileURLWithPath: "/synthetic/audio.wav")
        let remote = try #require(URL(string: "https://example.invalid/audio.mp3"))
        let existingFile = try #require(Bundle.main.executableURL)
        #expect(PlaybackSource.resolve(localURL: local, remoteURL: remote.absoluteString) == local)
        #expect(PlaybackSource.resolve(localURL: nil, remoteURL: remote.absoluteString) == remote)
        #expect(PlaybackSource.resolve(localURL: nil, remoteURL: existingFile.absoluteString) == existingFile)
        #expect(PlaybackSource.resolve(localURL: nil, remoteURL: "") == nil)
        #expect(PlaybackSource.resolve(localURL: nil, remoteURL: "file:///missing.wav") == nil)
        #expect(PlaybackSource.resolve(localURL: nil, remoteURL: "https://") == nil)
    }

    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        return queue
    }

    private func search(_ query: String, in queue: DatabaseQueue) throws -> MomentSearchResults {
        let pattern = try #require(MomentSearch.pattern(for: query))
        return try queue.read { try MomentSearch.search($0, pattern: pattern) }
    }

    private func insertFixture(_ db: Database) throws {
        try Podcast(feedURL: "fixture", title: "Synthetic show", author: nil, artworkURL: nil,
                    summary: nil, subscribedAt: Date(), adSkipMode: "ask").save(db)
        try Episode(id: "episode-1", podcastFeedURL: "fixture", title: "Synthetic episode",
                    summary: nil, audioURL: "", publishedAt: Date(), durationSeconds: 90,
                    downloadState: "none", localFilename: nil, playbackPositionSeconds: 0,
                    lastPlayedAt: nil, finished: false).save(db)
        try Snip(id: "snip-1", episodeId: "episode-1", startMs: 47_500, endMs: 60_000,
                 createdAt: Date(), starred: false, state: "enriched", title: "Lighthouse notes",
                 category: nil, takeawaysJSON: "[\"Synthetic takeaway\"]").save(db)
        try db.execute(sql: """
            INSERT INTO transcriptSegment (id, episodeId, idx, text, startMs, endMs)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: ["line-1", "episode-1", 0,
                             "The violet lantern marks the quiet harbor.", 42_250, 58_000])
        try db.execute(sql: """
            INSERT INTO transcriptSegment (id, episodeId, idx, text, startMs, endMs)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: ["line-2", "episode-1", 1, "The copper compass points north.", 5_000, 12_000])
    }
}
