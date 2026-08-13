import Foundation
import GRDB

/// GRDB/SQLite — committed in PRD §9.1 (timestamped segments are relational; FTS5 arrives with
/// transcripts in P2). One DatabaseQueue for the whole app; ValueObservation drives the UI.
final class AppDatabase: Sendable {
    static let shared = try! AppDatabase()

    let dbQueue: DatabaseQueue

    private init() throws {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("Hark", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("hark.sqlite").path)
        try migrator.migrate(dbQueue)
    }

    /// Directory downloaded audio lives in. Filenames only in the DB — the container path moves.
    static var audioDirectory: URL {
        let dir = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("Hark/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "podcast") { t in
                t.column("feedURL", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("author", .text)
                t.column("artworkURL", .text)
                t.column("summary", .text)
                t.column("subscribedAt", .datetime).notNull()
                t.column("adSkipMode", .text).notNull().defaults(to: "ask")
            }
            try db.create(table: "episode") { t in
                t.column("id", .text).primaryKey()
                t.column("podcastFeedURL", .text).notNull().indexed()
                    .references("podcast", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("summary", .text)
                t.column("audioURL", .text).notNull()
                t.column("publishedAt", .datetime)
                t.column("durationSeconds", .double)
                t.column("downloadState", .text).notNull().defaults(to: "none")
                t.column("localFilename", .text)
                t.column("playbackPositionSeconds", .double).notNull().defaults(to: 0)
                t.column("lastPlayedAt", .datetime)
                t.column("finished", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "snip") { t in
                t.column("id", .text).primaryKey()
                t.column("episodeId", .text).notNull().indexed()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("starred", .boolean).notNull().defaults(to: false)
                t.column("state", .text).notNull().defaults(to: "captured")
                t.column("title", .text)
            }
            try db.create(table: "playQueue") { t in
                t.column("episodeId", .text).primaryKey()
                t.column("position", .integer).notNull()
            }
        }

        // P2: the pipeline entities (PRD §9.4). Everything hangs off timestamped segments; the
        // per-stage artifactStatus table replaces a linear processing-state enum so "ads done,
        // summary failed" is representable and stages re-run when their model upgrades.
        migrator.registerMigration("v2-pipeline") { db in
            try db.create(table: "transcriptSegment") { t in
                t.column("id", .text).primaryKey()
                t.column("episodeId", .text).notNull().indexed()
                t.column("idx", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("speaker", .text)
            }
            try db.create(virtualTable: "transcriptSegment_ft", using: FTS5()) { t in
                t.synchronize(withTable: "transcriptSegment")
                t.column("text")
            }
            try db.create(table: "adRange") { t in
                t.column("id", .text).primaryKey()
                t.column("episodeId", .text).notNull().indexed()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("confidence", .double).notNull()
                t.column("userVerdict", .text).notNull().defaults(to: "unset")
            }
            try db.create(table: "chapter") { t in
                t.column("id", .text).primaryKey()
                t.column("episodeId", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
            }
            try db.create(table: "keyMoment") { t in
                t.column("id", .text).primaryKey()
                t.column("episodeId", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
            }
            try db.create(table: "episodeSummary") { t in
                t.column("episodeId", .text).primaryKey()
                t.column("tldr", .text).notNull()
                t.column("takeawaysJSON", .text).notNull()
            }
            try db.create(table: "artifactStatus") { t in
                t.column("episodeId", .text).notNull()
                t.column("stage", .text).notNull()
                t.column("status", .text).notNull()      // queued/running/done/failed/degraded
                t.column("modelVersion", .text)
                t.column("note", .text)
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["episodeId", "stage"])
            }
        }

        // v3: chunked-transcription coverage — which 3-minute windows of an episode are already
        // transcribed and persisted, so a killed/relaunched app never redoes finished work.
        migrator.registerMigration("v3-transcript-chunks") { db in
            try db.create(table: "transcriptChunk") { t in
                t.column("episodeId", .text).notNull()
                t.column("chunkIdx", .integer).notNull()
                t.primaryKey(["episodeId", "chunkIdx"])
            }
        }

        // v4: AI snip enrichment (PRD §8.4 card face) — category chip + takeaway bullets, written
        // by the on-device LLM once transcript text covers the snip. `title` already existed.
        migrator.registerMigration("v4-snip-enrichment") { db in
            try db.alter(table: "snip") { t in
                t.add(column: "category", .text)
                t.add(column: "takeawaysJSON", .text)
            }
        }
        return migrator
    }
}
