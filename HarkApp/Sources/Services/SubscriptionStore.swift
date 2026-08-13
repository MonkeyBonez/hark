import Foundation
import GRDB

/// Subscribe / refresh / unsubscribe — the library's write path. Reads happen via ValueObservation
/// in the views, so this store is intentionally stateless beyond the database itself.
@MainActor
final class SubscriptionStore: ObservableObject {
    private let db = AppDatabase.shared

    @Published var refreshing = false
    @Published var lastError: String?
    /// Bumped on every successful library write — views reload with .task(id:) off this.
    @Published var libraryVersion = 0

    func subscribe(feedURL: String) async {
        do {
            guard let url = URL(string: feedURL) else { throw FeedParserError.badXML }
            let feed = try await FeedParser.fetch(url)
            try await upsert(feed: feed, feedURL: feedURL)
        } catch {
            lastError = "Couldn't subscribe: \(error.localizedDescription)"
        }
    }

    func unsubscribe(feedURL: String) async {
        try? await db.dbQueue.write { db in
            _ = try Podcast.deleteOne(db, key: feedURL)   // episodes cascade
        }
        libraryVersion += 1
    }

    /// Pull every subscribed feed; upsert new episodes. Network-frugal enough for a manual pull +
    /// foreground refresh in P1 (BGAppRefresh scheduling is a later nicety).
    func refreshAll() async {
        refreshing = true
        defer { refreshing = false }
        let podcasts = (try? await db.dbQueue.read { try Podcast.fetchAll($0) }) ?? []
        await withTaskGroup(of: Void.self) { group in
            for podcast in podcasts {
                group.addTask { [weak self] in
                    guard let url = URL(string: podcast.feedURL),
                          let feed = try? await FeedParser.fetch(url) else { return }
                    try? await self?.upsert(feed: feed, feedURL: podcast.feedURL)
                }
            }
        }
    }

    private func upsert(feed: ParsedFeed, feedURL: String) async throws {
        try await db.dbQueue.write { db in
            let existing = try Podcast.fetchOne(db, key: feedURL)
            let podcast = Podcast(feedURL: feedURL,
                                  title: feed.title.isEmpty ? feedURL : feed.title,
                                  author: feed.author,
                                  artworkURL: feed.artworkURL,
                                  summary: feed.summary,
                                  subscribedAt: existing?.subscribedAt ?? Date(),
                                  adSkipMode: existing?.adSkipMode ?? "ask")
            try podcast.save(db)

            for item in feed.items {
                guard let audioURL = item.enclosureURL else { continue }
                let id = item.guid ?? audioURL
                if var current = try Episode.fetchOne(db, key: id) {
                    // Keep user state (download/progress); refresh feed-provided metadata.
                    current.title = item.title
                    current.summary = item.summary ?? current.summary
                    current.durationSeconds = item.durationSeconds ?? current.durationSeconds
                    try current.save(db)
                } else {
                    try Episode(id: id, podcastFeedURL: feedURL, title: item.title,
                                summary: item.summary, audioURL: audioURL,
                                publishedAt: item.pubDate, durationSeconds: item.durationSeconds,
                                downloadState: Episode.DownloadState.none.rawValue,
                                localFilename: nil, playbackPositionSeconds: 0,
                                lastPlayedAt: nil, finished: false).save(db)
                }
            }
        }
        libraryVersion += 1
    }
}

/// OPML import — the switcher path (PRD §8.9). Collects every outline xmlUrl and subscribes.
enum OPMLImporter {
    static func feedURLs(from data: Data) -> [String] {
        final class Collector: NSObject, XMLParserDelegate {
            var urls: [String] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                if name == "outline", let url = attributes["xmlUrl"] ?? attributes["xmlURL"] {
                    urls.append(url)
                }
            }
        }
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.urls
    }
}
