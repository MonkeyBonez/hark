import SwiftUI
import GRDB

/// Discover: directory search (iTunes Search API) front and center, your shows as an artwork grid.
struct DiscoverView: View {
    @EnvironmentObject var subscriptions: SubscriptionStore

    @State private var query = ""
    @State private var results: [ITunesSearchClient.Result] = []
    @State private var searching = false
    @State private var subscribed: [Podcast] = []

    private let client = ITunesSearchClient()

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section(searching ? "Searching…" : "Results") {
                        ForEach(results) { result in
                            SearchResultRow(result: result, isSubscribed: isSubscribed(result))
                        }
                    }
                }
                if !subscribed.isEmpty {
                    Section("Your shows") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 16) {
                            ForEach(subscribed) { podcast in
                                NavigationLink(value: podcast.feedURL) {
                                    VStack(spacing: 6) {
                                        ArtworkView(urlString: podcast.artworkURL, size: 100)
                                        Text(podcast.title)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: 100)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Discover")
            .navigationDestination(for: String.self) { feedURL in
                PodcastDetailView(feedURL: feedURL)
            }
            .searchable(text: $query, prompt: "Find a podcast")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty { results = [] }
            }
            .onAppear(perform: loadSubscribed)
            .task(id: subscriptions.libraryVersion) { loadSubscribed() }
        }
    }

    private func isSubscribed(_ result: ITunesSearchClient.Result) -> Bool {
        guard let feed = result.feedUrl else { return false }
        return subscribed.contains { $0.feedURL == feed }
    }

    private func runSearch() async {
        searching = true
        defer { searching = false }
        results = (try? await client.search(query)) ?? []
    }

    private func loadSubscribed() {
        subscribed = (try? AppDatabase.shared.dbQueue.read {
            try Podcast.order(Column("title")).fetchAll($0)
        }) ?? []
    }
}

struct SearchResultRow: View {
    @EnvironmentObject var subscriptions: SubscriptionStore
    let result: ITunesSearchClient.Result
    let isSubscribed: Bool
    @State private var working = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(urlString: result.artworkUrl600, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.collectionName).font(.subheadline.weight(.medium)).lineLimit(2)
                if let artist = result.artistName {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                guard let feed = result.feedUrl else { return }
                working = true
                Task {
                    await subscriptions.subscribe(feedURL: feed)
                    working = false
                }
            } label: {
                if working { ProgressView().controlSize(.small) }
                else if isSubscribed { Image(systemName: "checkmark.circle.fill") }
                else { Text("Subscribe").font(.caption.weight(.semibold)) }
            }
            .buttonStyle(.bordered)
            .disabled(isSubscribed || working)
        }
    }
}

/// Podcast page: header + every episode through the shared row (download / summarize / queue).
struct PodcastDetailView: View {
    @EnvironmentObject var subscriptions: SubscriptionStore
    let feedURL: String

    @State private var podcast: Podcast?
    @State private var episodes: [Episode] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let podcast {
                Section {
                    HStack(spacing: 14) {
                        ArtworkView(urlString: podcast.artworkURL, size: 88)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(podcast.title).font(.headline)
                            if let author = podcast.author {
                                Text(author).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(episodes.count) episodes")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("Episodes") {
                ForEach(episodes) { ep in
                    EpisodeRow(episode: ep, podcast: podcast)
                }
            }
        }
        .navigationTitle(podcast?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button(role: .destructive) {
                    Task {
                        await subscriptions.unsubscribe(feedURL: feedURL)
                        dismiss()
                    }
                } label: { Label("Unsubscribe", systemImage: "minus.circle") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .onAppear(perform: load)
        .task(id: subscriptions.libraryVersion) { load() }
    }

    private func load() {
        let db = AppDatabase.shared.dbQueue
        podcast = try? db.read { try Podcast.fetchOne($0, key: feedURL) }
        episodes = (try? db.read {
            try Episode.filter(Column("podcastFeedURL") == feedURL)
                .order(Column("publishedAt").desc).fetchAll($0)
        }) ?? []
    }
}
