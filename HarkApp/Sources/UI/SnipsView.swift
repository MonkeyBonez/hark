import SwiftUI
import GRDB

/// Snips library (PRD §8.5): the words you saved, searchable, starred section on top, grouped by
/// episode. Excerpts are derived on the fly from transcript segments overlapping each snip's raw
/// time window (§9.4 — no text copies), so cards upgrade in place once an episode is processed.
struct SnipsView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var processing: ProcessingService

    struct Card: Identifiable {
        let snip: Snip
        let episode: Episode
        let podcast: Podcast?
        let excerpt: String?
        var id: String { snip.id }
    }

    @State private var cards: [Card] = []
    @State private var query = ""
    @State private var selected: Card?

    private var filtered: [Card] {
        guard !query.isEmpty else { return cards }
        let q = query.localizedLowercase
        return cards.filter {
            ($0.excerpt?.localizedLowercase.contains(q) ?? false)
                || ($0.snip.title?.localizedLowercase.contains(q) ?? false)
                || $0.episode.title.localizedLowercase.contains(q)
        }
    }

    private var starred: [Card] { filtered.filter(\.snip.starred) }

    /// Episode groups in recency order (cards are already createdAt-desc).
    private var groups: [(episode: Episode, cards: [Card])] {
        var order: [String] = []
        var byEpisode: [String: [Card]] = [:]
        for card in filtered {
            if byEpisode[card.episode.id] == nil { order.append(card.episode.id) }
            byEpisode[card.episode.id, default: []].append(card)
        }
        return order.compactMap { id in
            byEpisode[id].map { (episode: $0[0].episode, cards: $0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if cards.isEmpty {
                    ContentUnavailableView(
                        "No snips yet",
                        systemImage: "scissors",
                        description: Text("While listening, tap the scissors — or the bookmark button on your lock screen — to save the moment you just heard.")
                    )
                } else {
                    if !starred.isEmpty {
                        Section("Starred") {
                            ForEach(starred) { row($0, showsEpisode: true) }
                        }
                    }
                    ForEach(groups, id: \.episode.id) { group in
                        Section(group.episode.title) {
                            ForEach(group.cards) { row($0, showsEpisode: false) }
                        }
                    }
                }
            }
            .navigationTitle("Snips")
            .searchable(text: $query, prompt: "Search your snips")
            .onAppear {
                load()
                processing.enrichPendingSnips()   // catch snips still untitled from a past session
            }
            .task(id: player.snipToastText) { load() }              // a fresh capture appears live
            .task(id: processing.transcriptVersion) { load() }      // excerpts + AI titles land live
            .sheet(item: $selected) { card in
                SnipDetailView(snip: card.snip, episode: card.episode, onChange: load)
            }
        }
    }

    private func row(_ card: Card, showsEpisode: Bool) -> some View {
        SnipCardRow(card: card, showsEpisode: showsEpisode) {
            player.play(card.episode, resume: false)
            player.seek(to: Double(card.snip.startMs) / 1000)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = card }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                try? AppDatabase.shared.dbQueue.write { _ = try Snip.deleteOne($0, key: card.snip.id) }
                load()
            } label: { Label("Delete", systemImage: "trash") }
            Button {
                var updated = card.snip
                updated.starred.toggle()
                try? AppDatabase.shared.dbQueue.write { try updated.save($0) }
                load()
            } label: {
                Label(card.snip.starred ? "Unstar" : "Star",
                      systemImage: card.snip.starred ? "star.slash" : "star")
            }.tint(.yellow)
        }
    }

    private func load() {
        let db = AppDatabase.shared.dbQueue
        let raw: [(Snip, Episode, Podcast?)] = (try? db.read { db in
            let snips = try Snip.order(Column("createdAt").desc).fetchAll(db)
            return try snips.compactMap { snip in
                guard let ep = try Episode.fetchOne(db, key: snip.episodeId) else { return nil }
                return (snip, ep, try Podcast.fetchOne(db, key: ep.podcastFeedURL))
            }
        }) ?? []

        // One segments fetch per episode, however many snips it has.
        var segmentCache: [String: [TranscriptLine]] = [:]
        cards = raw.map { snip, episode, podcast in
            let segments: [TranscriptLine]
            if let cached = segmentCache[episode.id] {
                segments = cached
            } else {
                segments = ProcessingService.shared.segments(for: episode.id)
                segmentCache[episode.id] = segments
            }
            let text = segments
                .filter { $0.endMs > snip.startMs && $0.startMs < snip.endMs }
                .map(\.text).joined(separator: " ")
            return Card(snip: snip, episode: episode, podcast: podcast,
                        excerpt: text.isEmpty ? nil : text)
        }
    }
}

/// Just the current episode's snips — presented as a sheet from the player.
struct EpisodeSnipsView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var processing: ProcessingService
    @Environment(\.dismiss) private var dismiss
    let episode: Episode

    @State private var cards: [SnipsView.Card] = []
    @State private var selected: SnipsView.Card?

    var body: some View {
        NavigationStack {
            List {
                if cards.isEmpty {
                    ContentUnavailableView(
                        "No snips yet",
                        systemImage: "scissors",
                        description: Text("Tap the scissors while listening to save the moment you just heard.")
                    )
                } else {
                    ForEach(cards) { card in
                        SnipCardRow(card: card, showsEpisode: false) {
                            player.play(card.episode, resume: false)
                            player.seek(to: Double(card.snip.startMs) / 1000)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = card }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                try? AppDatabase.shared.dbQueue.write { _ = try Snip.deleteOne($0, key: card.snip.id) }
                                load()
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("Snips from this episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .onAppear(perform: load)
        .task(id: processing.transcriptVersion) { load() }
        .task(id: player.snipToastText) { load() }
        .sheet(item: $selected) { card in
            SnipDetailView(snip: card.snip, episode: card.episode, onChange: load)
        }
    }

    private func load() {
        let db = AppDatabase.shared.dbQueue
        let rows: [(Snip, Podcast?)] = (try? db.read { db in
            let snips = try Snip.filter(Column("episodeId") == episode.id)
                .order(Column("createdAt").desc).fetchAll(db)
            let podcast = try Podcast.fetchOne(db, key: episode.podcastFeedURL)
            return snips.map { ($0, podcast) }
        }) ?? []
        let segments = processing.segments(for: episode.id)
        cards = rows.map { snip, podcast in
            let text = segments
                .filter { $0.endMs > snip.startMs && $0.startMs < snip.endMs }
                .map(\.text).joined(separator: " ")
            return SnipsView.Card(snip: snip, episode: episode, podcast: podcast,
                                  excerpt: text.isEmpty ? nil : text)
        }
    }
}

/// One saved moment. The preview is deliberately just the AI title + takeaway text — the full
/// transcript quote lives one tap away in the detail view.
struct SnipCardRow: View {
    @EnvironmentObject var processing: ProcessingService
    let card: SnipsView.Card
    let showsEpisode: Bool
    var onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = card.snip.title {
                Text(title).font(.subheadline.weight(.semibold))
            } else {
                HStack(spacing: 6) {
                    Text("\(PlayerEngine.clock(card.snip.startMs)) – \(PlayerEngine.clock(card.snip.endMs))")
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                    if processing.enrichingSnips.contains(card.snip.id) {
                        ProgressView().controlSize(.mini)
                        Text("Naming…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(card.snip.takeaways, id: \.self) { takeaway in
                HStack(alignment: .top, spacing: 5) {
                    Text("•").foregroundStyle(.secondary)
                    Text(takeaway).lineLimit(2)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if showsEpisode {
                Text(card.episode.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                if card.snip.starred {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
                Text(PlayerEngine.clock(card.snip.startMs))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(card.snip.createdAt, style: .date)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: onPlay) {
                    Image(systemName: "play.circle").font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}
