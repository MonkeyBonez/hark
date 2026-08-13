import SwiftUI
import GRDB
import UniformTypeIdentifiers

/// You (PRD §8.6, §8.8): the queue, the processing queue (honest machinery), library maintenance,
/// storage, and minimal playback settings. No upsell — there is nothing to upsell.
struct YouView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var subscriptions: SubscriptionStore
    @EnvironmentObject var processing: ProcessingService

    @State private var queue: [(Episode, Podcast?)] = []
    @State private var jobEpisodes: [String: Episode] = [:]
    @State private var storageBytes: Int64 = 0
    @State private var showOPMLImporter = false
    @State private var opmlStatus: String?

    private let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// Every episode with a non-idle pipeline state, resolved to its DB row.
    private var activeJobs: [(episode: Episode, state: ProcessingService.EpisodeState)] {
        processing.states.compactMap { id, state in
            guard state != .idle, let ep = jobEpisodes[id] else { return nil }
            return (ep, state)
        }
        .sorted { $0.episode.title < $1.episode.title }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Up next") {
                    if queue.isEmpty {
                        Text("Queue is empty — swipe an episode and tap Queue.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(queue, id: \.0.id) { pair in
                            HStack(spacing: 12) {
                                ArtworkView(urlString: pair.1?.artworkURL, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pair.0.title).font(.subheadline).lineLimit(2)
                                    if let title = pair.1?.title {
                                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button { player.play(pair.0) } label: {
                                    Image(systemName: "play.circle").font(.title3)
                                }.buttonStyle(.plain)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { player.removeFromQueue(queue[i].0.id) }
                            load()
                        }
                    }
                }

                if !activeJobs.isEmpty {
                    Section {
                        ForEach(activeJobs, id: \.episode.id) { job in
                            HStack {
                                Text(job.episode.title).font(.subheadline).lineLimit(2)
                                Spacer()
                                jobStatus(job.state, episodeId: job.episode.id)
                            }
                        }
                    } header: {
                        Text("Transcribing")
                    } footer: {
                        Text("Transcription runs on-device and only while Hark is open. Finished chunks are saved as they go.")
                    }
                }

                Section("Library") {
                    Button {
                        showOPMLImporter = true
                    } label: {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                    }
                    if let status = opmlStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await subscriptions.refreshAll(); load() }
                    } label: {
                        HStack {
                            Label("Refresh all feeds", systemImage: "arrow.clockwise")
                            if subscriptions.refreshing { Spacer(); ProgressView().controlSize(.small) }
                        }
                    }
                }

                Section("Storage") {
                    LabeledContent("Downloaded audio",
                                   value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                }

                Section {
                    Picker("Speed", selection: $player.rate) {
                        ForEach(rates, id: \.self) { r in
                            Text(String(format: "%.2gx", r)).tag(r)
                        }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Snip gesture: the lock-screen bookmark button captures the last 30 seconds.")
                }
            }
            .navigationTitle("You")
            .onAppear { load(); measureStorage() }
            .task(id: processing.states) { load() }
            .fileImporter(isPresented: $showOPMLImporter,
                          allowedContentTypes: [.xml, UTType(filenameExtension: "opml") ?? .xml]) { result in
                guard case .success(let url) = result else { return }
                Task { await importOPML(url) }
            }
        }
    }

    @ViewBuilder private func jobStatus(_ state: ProcessingService.EpisodeState, episodeId: String) -> some View {
        switch state {
        case .running(let stage):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(processingStageLabel(stage, transcriptionFraction: processing.transcriptionProgress[episodeId]))
                    .font(.caption).foregroundStyle(.purple)
            }
        case .done:
            Label("Transcript ready", systemImage: "text.quote")
                .font(.caption).foregroundStyle(.purple)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private func load() {
        let db = AppDatabase.shared.dbQueue
        let jobIds = Array(processing.states.keys)
        let data: ([(Episode, Podcast?)], [String: Episode])? = try? db.read { db in
            let items = try PlayQueueItem.order(Column("position")).fetchAll(db)
            let q: [(Episode, Podcast?)] = try items.compactMap { item in
                guard let ep = try Episode.fetchOne(db, key: item.episodeId) else { return nil }
                return (ep, try Podcast.fetchOne(db, key: ep.podcastFeedURL))
            }
            var jobs: [String: Episode] = [:]
            for id in jobIds { jobs[id] = try Episode.fetchOne(db, key: id) }
            return (q, jobs)
        }
        queue = data?.0 ?? []
        jobEpisodes = data?.1 ?? [:]
    }

    private func measureStorage() {
        let dir = AppDatabase.audioDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        storageBytes = files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func importOPML(_ url: URL) async {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            opmlStatus = "Couldn't read that file."
            return
        }
        let feeds = OPMLImporter.feedURLs(from: data)
        guard !feeds.isEmpty else {
            opmlStatus = "No feeds found in that OPML."
            return
        }
        opmlStatus = "Importing \(feeds.count) feeds…"
        for feed in feeds {
            await subscriptions.subscribe(feedURL: feed)
        }
        opmlStatus = "Imported \(feeds.count) feeds."
    }
}
