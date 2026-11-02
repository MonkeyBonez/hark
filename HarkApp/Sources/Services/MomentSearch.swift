import Foundation
import GRDB

struct MomentSearchResult: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case transcript, snip
    }

    let kind: Kind
    let recordID: String
    let episodeID: String
    let episodeTitle: String
    let podcastTitle: String?
    let startMs: Int
    let title: String?
    let excerpt: String

    var id: String { "\(kind.rawValue):\(recordID)" }
}

struct MomentSearchResults: Equatable, Sendable {
    let snips: [MomentSearchResult]
    let transcript: [MomentSearchResult]

    var isEmpty: Bool { snips.isEmpty && transcript.isEmpty }
}

struct MomentDestination: Sendable {
    let episode: Episode
    let snip: Snip?
    let startMs: Int
}

enum MomentSearch {
    static let maximumQueryLength = 200
    static let resultLimit = 50

    /// Treat the input as words, never as FTS or SQL syntax.
    static func pattern(for query: String) -> FTS5Pattern? {
        guard query.count <= maximumQueryLength,
              query.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        return FTS5Pattern(matchingAllTokensIn: query.precomposedStringWithCanonicalMapping)
    }

    static func observation(for pattern: FTS5Pattern) -> ValueObservation<ValueReducers.Fetch<MomentSearchResults>> {
        ValueObservation.tracking(
            region: Table("transcriptSegment"), Table("snip"), Table("episode"), Table("podcast")
        ) { db in
            try search(db, pattern: pattern)
        }
    }

    static func search(_ db: Database, pattern: FTS5Pattern) throws -> MomentSearchResults {
        let transcriptRows = try Row.fetchAll(db, sql: """
            SELECT segment.id AS recordID, segment.episodeId AS episodeID,
                   episode.title AS episodeTitle, podcast.title AS podcastTitle,
                   segment.startMs AS startMs,
                   snippet(transcriptSegment_ft, 0, '', '', '…', 20) AS excerpt
            FROM transcriptSegment_ft
            JOIN transcriptSegment AS segment ON segment.rowid = transcriptSegment_ft.rowid
            JOIN episode ON episode.id = segment.episodeId
            LEFT JOIN podcast ON podcast.feedURL = episode.podcastFeedURL
            WHERE transcriptSegment_ft MATCH ?
            ORDER BY rank, episode.title COLLATE NOCASE, segment.startMs, segment.id
            LIMIT ?
            """, arguments: [pattern, resultLimit])
        let transcript = transcriptRows.map { result(from: $0, kind: .transcript) }

        let metadataRows = try Row.fetchAll(db, sql: """
            SELECT snip.id AS recordID, snip.episodeId AS episodeID,
                   episode.title AS episodeTitle, podcast.title AS podcastTitle,
                   snip.startMs AS startMs, snip.title AS title, snip.takeawaysJSON,
                   (SELECT segment.text FROM transcriptSegment AS segment
                    WHERE segment.episodeId = snip.episodeId
                      AND segment.endMs > snip.startMs AND segment.startMs < snip.endMs
                    ORDER BY segment.startMs, segment.id LIMIT 1) AS excerpt
            FROM snip_ft
            JOIN snip ON snip.rowid = snip_ft.rowid
            JOIN episode ON episode.id = snip.episodeId
            LEFT JOIN podcast ON podcast.feedURL = episode.podcastFeedURL
            WHERE snip_ft MATCH ?
            ORDER BY rank, episode.title COLLATE NOCASE, snip.startMs, snip.id
            LIMIT ?
            """, arguments: [pattern, resultLimit])

        // A snip's excerpt is not copied into its record: find matching indexed lines that
        // overlap the saved time window, and keep the first matching line for each snip.
        let excerptRows = try Row.fetchAll(db, sql: """
            WITH matches AS (
                SELECT snip.id AS recordID, snip.episodeId AS episodeID,
                       episode.title AS episodeTitle, podcast.title AS podcastTitle,
                       snip.startMs AS startMs, snip.title AS title, segment.text AS excerpt,
                       ROW_NUMBER() OVER (
                           PARTITION BY snip.id ORDER BY segment.startMs, segment.id
                       ) AS matchOrder
                FROM transcriptSegment_ft
                JOIN transcriptSegment AS segment ON segment.rowid = transcriptSegment_ft.rowid
                JOIN snip ON snip.episodeId = segment.episodeId
                    AND segment.endMs > snip.startMs AND segment.startMs < snip.endMs
                JOIN episode ON episode.id = snip.episodeId
                LEFT JOIN podcast ON podcast.feedURL = episode.podcastFeedURL
                WHERE transcriptSegment_ft MATCH ?
            )
            SELECT * FROM matches WHERE matchOrder = 1
            ORDER BY episodeTitle COLLATE NOCASE, startMs, recordID
            LIMIT ?
            """, arguments: [pattern, resultLimit])

        var snipsByID: [String: MomentSearchResult] = [:]
        for row in metadataRows {
            let hit = result(from: row, kind: .snip)
            snipsByID[hit.recordID] = hit
        }
        for row in excerptRows {
            let hit = result(from: row, kind: .snip)
            snipsByID[hit.recordID] = hit
        }
        let snips = snipsByID.values.sorted { lhs, rhs in
            let comparison = lhs.episodeTitle.localizedCaseInsensitiveCompare(rhs.episodeTitle)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            return lhs.recordID < rhs.recordID
        }
        return MomentSearchResults(snips: Array(snips.prefix(resultLimit)), transcript: transcript)
    }

    /// Re-read the selected record so an edit or deletion after the search cannot seek to stale
    /// data. Transcript hits seek to the line; snip hits seek to the saved snip boundary.
    static func destination(for result: MomentSearchResult, in db: Database) throws -> MomentDestination? {
        switch result.kind {
        case .transcript:
            guard let row = try Row.fetchOne(db, sql: """
                SELECT episodeId, startMs FROM transcriptSegment WHERE id = ?
                """, arguments: [result.recordID]),
                  let episode = try Episode.fetchOne(db, key: row["episodeId"] as String),
                  let startMs = row["startMs"] as Int?, startMs >= 0 else { return nil }
            return MomentDestination(episode: episode, snip: nil, startMs: startMs)
        case .snip:
            guard let snip = try Snip.fetchOne(db, key: result.recordID),
                  snip.startMs >= 0,
                  let episode = try Episode.fetchOne(db, key: snip.episodeId) else { return nil }
            return MomentDestination(episode: episode, snip: snip, startMs: snip.startMs)
        }
    }

    private static func result(from row: Row, kind: MomentSearchResult.Kind) -> MomentSearchResult {
        let title: String? = kind == .snip ? row["title"] : nil
        var excerpt: String? = row["excerpt"]
        if (excerpt?.isEmpty ?? true), kind == .snip,
           row.hasColumn("takeawaysJSON"), let json: String = row["takeawaysJSON"],
           let takeaways = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
            excerpt = takeaways.first
        }
        return MomentSearchResult(
            kind: kind, recordID: row["recordID"], episodeID: row["episodeID"],
            episodeTitle: row["episodeTitle"], podcastTitle: row["podcastTitle"],
            startMs: row["startMs"], title: title, excerpt: excerpt ?? ""
        )
    }
}
