import Foundation
import GRDB

// The P1 slice of the PRD §9.4 data model: Podcast / Episode / Snip / PlayQueue.
// Pipeline entities (Transcript, AdRange, Chapter, ProcessingJob, ModelAsset…) arrive in P2.

struct Podcast: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "podcast"

    /// The feed URL doubles as the stable id — it is the one thing every source of a podcast shares.
    var id: String { feedURL }
    var feedURL: String
    var title: String
    var author: String?
    var artworkURL: String?
    var summary: String?
    var subscribedAt: Date
    /// PRD §8.11 per-show ad-skip mode (on/off/ask). Stored now so P2 needs no migration.
    var adSkipMode: String

    enum CodingKeys: String, CodingKey {
        case feedURL, title, author, artworkURL, summary, subscribedAt, adSkipMode
    }

    static let episodes = hasMany(Episode.self)
}

struct Episode: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "episode"

    enum DownloadState: String, Codable {
        case none, downloading, downloaded, failed
    }

    /// guid when the feed provides one, else the enclosure URL.
    var id: String
    var podcastFeedURL: String
    var title: String
    var summary: String?
    var audioURL: String
    var publishedAt: Date?
    var durationSeconds: Double?
    var downloadState: String
    /// File name inside the app's Audio directory (never an absolute path — container moves).
    var localFilename: String?
    /// Raw seconds; PRD: playback position survives restarts.
    var playbackPositionSeconds: Double
    var lastPlayedAt: Date?
    var finished: Bool

    static let podcast = belongsTo(Podcast.self)

    var isDownloaded: Bool { DownloadState(rawValue: downloadState) == .downloaded && localFilename != nil }
}

/// A snip: a raw captured time window (PRD §8.4). Time is raw milliseconds, never a segment FK
/// (PRD §9.4). The AI fields (title/category/takeaways) are written by on-device enrichment once
/// transcript text covers the window — lifecycle: captured → enriched.
struct Snip: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "snip"

    var id: String
    var episodeId: String
    var startMs: Int
    var endMs: Int
    var createdAt: Date
    var starred: Bool
    /// captured → enriched
    var state: String
    var title: String?
    /// SnipEnrichment.Category rawValue: insight / quote / takeaway / question / story.
    var category: String?
    var takeawaysJSON: String?

    var takeaways: [String] {
        guard let json = takeawaysJSON else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}

/// A transcript segment as the UI consumes it (one finalized sentence/clause with its time span).
/// Read model only — not a GRDB record; hydrated from the `transcriptSegment` table for the
/// follow-along transcript and for deriving snip text on the fly.
struct TranscriptLine: Identifiable, Equatable {
    let id: String
    let text: String
    let startMs: Int
    let endMs: Int
    let speaker: String?
}

struct PlayQueueItem: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playQueue"
    var id: String { episodeId }
    var episodeId: String
    var position: Int

    enum CodingKeys: String, CodingKey { case episodeId, position }
}
