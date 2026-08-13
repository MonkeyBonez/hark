import SwiftUI
import GRDB

/// The hero screen (PRD §8.1). Transport stays pinned at the thumb; the upper half morphs between
/// the artwork hero (with an honest transcript status card: download → transcribe → live percent →
/// failure/retry) and — as soon as any transcript text exists — the inline karaoke transcript,
/// which grows live while chunked transcription runs.
struct PlayerView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var processing: ProcessingService
    @EnvironmentObject var downloads: DownloadManager

    @State private var scrubbing = false
    @State private var scrubTime: Double = 0
    /// Fresh DB row for the current episode — download state changes underneath the player.
    @State private var episode: Episode?
    @State private var chapters: [(title: String, startMs: Int, endMs: Int)] = []
    @State private var lines: [TranscriptLine] = []
    @State private var snipCount = 0
    @State private var showSnips = false
    /// The rate when a speed-scrub drag began; nil while not dragging.
    @State private var rateDragBase: Float?

    private var nowMs: Int { Int(player.currentTime * 1000) }
    private var currentChapter: (title: String, startMs: Int, endMs: Int)? {
        chapters.first { nowMs >= $0.startMs && nowMs < $0.endMs }
    }

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(.tertiary).frame(width: 36, height: 5).padding(.top, 10)

            if lines.isEmpty { heroArea } else { transcriptArea }

            scrubber
            transport
            actionRow
        }
        .padding(.bottom, 14)
        .presentationDetents([.large])
        .task(id: player.currentEpisode?.id) { reload() }
        .task(id: player.currentEpisode.map { processing.state(for: $0.id) }) { reload() }
        .task(id: player.currentEpisode.map { downloads.isDownloading($0.id) }) { reload() }
        .task(id: processing.transcriptVersion) { reload() }
        .task(id: player.snipToastText) { reload() }
        .sheet(isPresented: $showSnips) {
            if let ep = episode {
                EpisodeSnipsView(episode: ep)
            }
        }
    }

    // MARK: Upper half — pre-transcript hero

    private var heroArea: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            ArtworkView(urlString: player.currentPodcast?.artworkURL, size: 250)
                .shadow(radius: 14, y: 8)
            VStack(spacing: 6) {
                Text(player.currentEpisode?.title ?? "")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(player.currentPodcast?.title ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            transcriptStatusCard
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The one honest status surface (PRD §8.6): what stands between this episode and its live
    /// transcript, and the single tap that advances it. Transcription auto-starts on play, so the
    /// common sight here is the progress bar.
    @ViewBuilder private var transcriptStatusCard: some View {
        if let ep = episode {
            switch processing.state(for: ep.id) {
            case .running(let stage):
                VStack(spacing: 8) {
                    if let f = processing.transcriptionProgress[ep.id] {
                        ProgressView(value: f).frame(width: 200)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(processingStageLabel(stage, transcriptionFraction: processing.transcriptionProgress[ep.id]))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(spacing: 8) {
                    Label("Couldn't transcribe this episode", systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.red)
                    Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    Button("Try again") { processing.transcribe(ep) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 30)
            default:
                if ep.isDownloaded {
                    VStack(spacing: 6) {
                        Button { processing.transcribe(ep) } label: {
                            Label("Transcribe episode", systemImage: "text.quote")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        Text("Starts near where you're listening — the live transcript and snip text appear as it runs.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                } else if downloads.isDownloading(ep.id) {
                    HStack(spacing: 8) {
                        ProgressView(value: downloads.progress[ep.id] ?? 0).frame(width: 90)
                        Text("Downloading…").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 6) {
                        Button { downloads.download(ep) } label: {
                            Label("Download episode", systemImage: "arrow.down.circle")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        Text("Download to transcribe, follow along, and snip.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Upper half — inline karaoke transcript

    private var transcriptArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ArtworkView(urlString: player.currentPodcast?.artworkURL, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.currentEpisode?.title ?? "")
                        .font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(player.currentPodcast?.title ?? "")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let ep = episode, let f = processing.transcriptionProgress[ep.id] {
                    Text("\(Int(f * 100))%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.purple)
                }
            }
            .padding(.horizontal, 20)

            KaraokeTranscriptView(lines: lines)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Pinned chrome

    private var scrubber: some View {
        VStack(spacing: 4) {
            if let chapter = currentChapter {
                Text(chapter.title)
                    .font(.caption)
                    .foregroundStyle(chapter.title == "Sponsor break" ? AnyShapeStyle(.orange)
                                                                      : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubTime : player.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(player.duration, 1)
            ) { editing in
                scrubbing = editing
                if !editing { player.seek(to: scrubTime) }
            }
            HStack {
                Text(PlayerEngine.clock(Int(player.currentTime * 1000)))
                Spacer()
                Text("-" + PlayerEngine.clock(Int(max(0, player.duration - player.currentTime) * 1000)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button { player.skip(-10) } label: {
                Image(systemName: "gobackward.10").font(.title)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            Button { player.skip(30) } label: {
                Image(systemName: "goforward.30").font(.title)
            }
        }
        .foregroundStyle(.primary)
    }

    private var actionRow: some View {
        HStack {
            // Scrubbable speed: drag the pill left/right (0.05x steps, 0.5–3x). Double-tap → 1x.
            Text(String(format: "%gx", (Double(player.rate) * 100).rounded() / 100))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(rateDragBase == nil ? AnyShapeStyle(.quaternary)
                                                : AnyShapeStyle(.tint.opacity(0.2)), in: Capsule())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let base = rateDragBase ?? player.rate
                            if rateDragBase == nil { rateDragBase = player.rate }
                            let raw = base + Float(value.translation.width / 120)
                            player.rate = min(3.0, max(0.5, (raw * 20).rounded() / 20))
                        }
                        .onEnded { _ in rateDragBase = nil }
                )
                .onTapGesture(count: 2) { player.rate = 1.0 }

            if snipCount > 0 {
                Button { showSnips = true } label: {
                    Text("\(snipCount) snip\(snipCount == 1 ? "" : "s")")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.quaternary, in: Capsule())
                }
                .padding(.leading, 10)
            }

            Spacer()

            // The persistent snip pill — one thumb-tap away (PRD §8.1).
            Button { player.captureSnip() } label: {
                Label("Create snip", systemImage: "scissors")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 24)
    }

    private func reload() {
        guard let id = player.currentEpisode?.id else {
            episode = nil; chapters = []; lines = []; snipCount = 0
            return
        }
        episode = (try? AppDatabase.shared.dbQueue.read { try Episode.fetchOne($0, key: id) })
            ?? player.currentEpisode
        chapters = processing.chapters(for: id)
        lines = processing.segments(for: id)
        snipCount = (try? AppDatabase.shared.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM snip WHERE episodeId = ?", arguments: [id]) ?? 0
        }) ?? 0
    }
}
