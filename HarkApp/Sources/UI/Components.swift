import SwiftUI
import GRDB

// Shared UI atoms — one place, one look: artwork, the episode row, the mini player.

/// Human phrase for a pipeline stage token; transcription is the long pole (shows live percent),
/// then the on-device model takes over ("summarizing"), then a quick "saving".
func processingStageLabel(_ stage: String, transcriptionFraction: Double? = nil) -> String {
    if stage == "transcribing", let f = transcriptionFraction {
        return "Transcribing \(Int(min(1, f) * 100))%"
    }
    switch stage {
    case "queued": return "Queued…"
    case "transcribing": return "Transcribing…"
    case "summarizing": return "Summarizing…"
    case "saving": return "Saving…"
    default: return stage.capitalized + "…"
    }
}

struct ArtworkView: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size / 8)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "waveform").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
    }
}

/// Lives in the tab view's bottom accessory slot — the system draws the glass capsule, so this is
/// just the content row. Tap anywhere → full player; scissors and play/pause stay one tap away.
struct MiniPlayerBar: View {
    @EnvironmentObject var player: PlayerEngine
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(urlString: player.currentPodcast?.artworkURL, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentEpisode?.title ?? "")
                    .font(.footnote.weight(.medium)).lineLimit(1)
                Text(player.currentPodcast?.title ?? "")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { player.captureSnip() } label: {
                Image(systemName: "scissors").font(.body)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// The one episode row, used everywhere an episode is listed. Tap plays; swipe queues, summarizes,
/// or removes the download. It re-reads its own DB row when a download finishes and re-checks for
/// AI artifacts when processing state changes — so badges never go stale.
struct EpisodeRow: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var processing: ProcessingService

    let episode: Episode
    var podcast: Podcast?
    var showResumeBar = false

    @State private var fresh: Episode?
    @State private var hasTx = false
    @State private var showError = false

    /// The episode as the DB currently has it — `episode` is a snapshot from the parent's load.
    private var ep: Episode { fresh ?? episode }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(urlString: podcast?.artworkURL, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(ep.title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if let date = ep.publishedAt {
                        Text(date, style: .date)
                    }
                    if let dur = ep.durationSeconds {
                        Text("·")
                        Text(PlayerEngine.clock(Int(dur * 1000)))
                    }
                    if ep.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill").font(.caption2)
                    }
                    processingBadge
                }
                .font(.caption).foregroundStyle(.secondary)
                if showResumeBar, let dur = ep.durationSeconds, dur > 0 {
                    ProgressView(value: min(ep.playbackPositionSeconds, dur), total: dur)
                        .tint(.accentColor)
                }
            }
            Spacer()
            accessory
        }
        .contentShape(Rectangle())
        .onTapGesture { player.play(ep) }
        .task(id: downloads.isDownloading(episode.id)) { refetch() }
        .task(id: processing.state(for: episode.id)) { refreshTranscriptFlag() }
        .task(id: processing.transcriptVersion) { refreshTranscriptFlag() }
        .swipeActions(edge: .trailing) {
            Button { player.enqueue(ep) } label: {
                Label("Queue", systemImage: "text.badge.plus")
            }.tint(.blue)
            if ep.isDownloaded {
                Button {
                    hasTx ? processing.retranscribe(ep) : processing.transcribe(ep)
                } label: {
                    Label(hasTx ? "Re-transcribe" : "Transcribe", systemImage: "text.quote")
                }.tint(.purple)
                Button(role: .destructive) {
                    downloads.delete(ep)
                    refetch()
                } label: { Label("Remove download", systemImage: "trash") }
            }
        }
        .alert("Couldn't transcribe episode", isPresented: $showError) {
            if ep.isDownloaded {
                Button("Retry") { processing.transcribe(ep) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(failureMessage ?? "Something went wrong while transcribing this episode.")
        }
    }

    private var failureMessage: String? {
        if case .failed(let m) = processing.state(for: episode.id) { return m }
        return nil
    }

    @ViewBuilder private var processingBadge: some View {
        switch processing.state(for: episode.id) {
        case .running(let stage):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(processingStageLabel(stage, transcriptionFraction: processing.transcriptionProgress[episode.id]))
                    .font(.caption2).foregroundStyle(.purple)
            }
        case .failed:
            Button { showError = true } label: {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium)).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        case .done:
            Image(systemName: "text.quote").font(.caption2).foregroundStyle(.purple)
        case .idle:
            if hasTx {
                Image(systemName: "text.quote").font(.caption2).foregroundStyle(.purple)
            }
        }
    }

    @ViewBuilder private var accessory: some View {
        if downloads.isDownloading(episode.id) {
            Button { downloads.cancel(episode.id) } label: {
                ProgressView(value: downloads.progress[episode.id] ?? 0)
                    .progressViewStyle(.circular).controlSize(.small)
            }
            .buttonStyle(.plain)
        } else if !ep.isDownloaded {
            Button { downloads.download(ep) } label: {
                Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func refetch() {
        fresh = try? AppDatabase.shared.dbQueue.read { try Episode.fetchOne($0, key: episode.id) }
    }

    /// The badge must survive app relaunch: in-memory state resets to .idle, so ask the DB whether
    /// any transcript text actually exists.
    private func refreshTranscriptFlag() {
        hasTx = processing.hasTranscript(for: episode.id)
    }
}
