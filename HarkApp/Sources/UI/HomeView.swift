import SwiftUI
import GRDB

/// Home = "what do I listen to right now": one hero card to jump back in, then the latest from
/// subscriptions. Reads are pull-on-appear + refreshable; `libraryVersion` re-pulls after
/// subscribe/refresh.
struct HomeView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Binding var showPlayer: Bool

    @State private var resumable: [(Episode, Podcast?)] = []
    @State private var latest: [(Episode, Podcast?)] = []

    var body: some View {
        NavigationStack {
            List {
                if let hero = resumable.first {
                    Section("Jump back in") {
                        ResumeCard(episode: hero.0, podcast: hero.1) {
                            player.play(hero.0)
                            showPlayer = true
                        }
                        ForEach(resumable.dropFirst(), id: \.0.id) { pair in
                            EpisodeRow(episode: pair.0, podcast: pair.1, showResumeBar: true)
                        }
                    }
                }
                Section(latest.isEmpty ? "" : "Latest") {
                    if latest.isEmpty {
                        ContentUnavailableView(
                            "Find your first show",
                            systemImage: "magnifyingglass",
                            description: Text("Search in Discover, or import an OPML file in You.")
                        )
                    } else {
                        ForEach(latest, id: \.0.id) { pair in
                            EpisodeRow(episode: pair.0, podcast: pair.1)
                        }
                    }
                }
            }
            .navigationTitle("Home")
            .refreshable {
                await subscriptions.refreshAll()
                load()
            }
            .onAppear(perform: load)
            .task(id: subscriptions.libraryVersion) { load() }
        }
    }

    private func load() {
        let db = AppDatabase.shared.dbQueue
        let rows: ([Episode], [Episode], [String: Podcast])? = try? db.read { db in
            let resume = try Episode
                .filter(Column("playbackPositionSeconds") > 30 && Column("finished") == false)
                .order(Column("lastPlayedAt").desc).limit(5).fetchAll(db)
            let recent = try Episode.order(Column("publishedAt").desc).limit(60).fetchAll(db)
            let podcasts = try Podcast.fetchAll(db)
            return (resume, recent, Dictionary(uniqueKeysWithValues: podcasts.map { ($0.feedURL, $0) }))
        }
        guard let (resume, recent, podcastMap) = rows else { return }
        resumable = resume.map { ($0, podcastMap[$0.podcastFeedURL]) }
        latest = recent.map { ($0, podcastMap[$0.podcastFeedURL]) }
    }
}

/// The hero: the episode you're mid-way through, one tap from artwork to full player.
struct ResumeCard: View {
    let episode: Episode
    var podcast: Podcast?
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ArtworkView(urlString: podcast?.artworkURL, size: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    if let dur = episode.durationSeconds, dur > 0 {
                        ProgressView(value: min(episode.playbackPositionSeconds, dur), total: dur)
                            .tint(.accentColor)
                        Text(PlayerEngine.clock(Int(max(0, dur - episode.playbackPositionSeconds) * 1000)) + " left")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let title = podcast?.title {
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
