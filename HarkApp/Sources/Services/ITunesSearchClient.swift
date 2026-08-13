import Foundation

/// Podcast directory search via the iTunes Search API — no key, no account, and the same index
/// Apple Podcasts itself searches. Network is directory-search-only per PRD §8.7.
struct ITunesSearchClient {
    struct Result: Identifiable, Decodable, Equatable {
        var id: Int { collectionId }
        let collectionId: Int
        let collectionName: String
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let genres: [String]?
    }

    private struct Envelope: Decodable { let results: [Result] }

    func search(_ term: String) async throws -> [Result] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "term", value: term),
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let hits = try JSONDecoder().decode(Envelope.self, from: data).results
        return hits.filter { $0.feedUrl != nil }   // a podcast without a feed can't be subscribed
    }
}
