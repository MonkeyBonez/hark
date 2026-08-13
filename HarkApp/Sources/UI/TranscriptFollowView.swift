import SwiftUI

/// Reusable line-level karaoke scroll (PRD §8.1): current line bright, upcoming dimmed, auto-scroll
/// that pauses on manual drag (Follow pill to resume), tap any line to seek. Embedded inline in the
/// player and full-screen in TranscriptFollowView. Lines grow live while chunked transcription runs.
struct KaraokeTranscriptView: View {
    @EnvironmentObject var player: PlayerEngine
    let lines: [TranscriptLine]

    @State private var autoScroll = true

    private var currentMs: Int { Int(player.currentTime * 1000) }

    private func isCurrent(_ line: TranscriptLine) -> Bool {
        currentMs >= line.startMs && currentMs < line.endMs
    }

    private var currentId: String? {
        lines.first(where: isCurrent)?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        let current = isCurrent(line)
                        Text(line.text)
                            .font(.body)
                            .fontWeight(current ? .semibold : .regular)
                            .foregroundStyle(current ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6).padding(.horizontal, 14)
                            .background(current ? Color.accentColor.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                autoScroll = true
                                player.seek(to: Double(line.startMs) / 1000)
                            }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            // Any manual drag pauses auto-follow until the user taps Follow (or a line).
            .simultaneousGesture(DragGesture().onChanged { _ in autoScroll = false })
            .onChange(of: currentId) { _, id in
                guard autoScroll, let id else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                if let id = currentId { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay(alignment: .bottom) {
                if !autoScroll {
                    Button {
                        autoScroll = true
                        if let id = currentId {
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    } label: {
                        Label("Follow", systemImage: "location.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }
}

/// Full-screen transcript sheet. Reloads as chunks land, so the text grows while you watch.
struct TranscriptFollowView: View {
    @EnvironmentObject var processing: ProcessingService
    @Environment(\.dismiss) private var dismiss
    let episodeId: String

    @State private var lines: [TranscriptLine] = []

    var body: some View {
        NavigationStack {
            Group {
                if lines.isEmpty {
                    ContentUnavailableView(
                        "No transcript yet",
                        systemImage: "text.quote",
                        description: Text("Play or transcribe this episode — the transcript appears here as it's generated.")
                    )
                } else {
                    KaraokeTranscriptView(lines: lines)
                }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: reload)
        .task(id: processing.transcriptVersion) { reload() }
    }

    private func reload() {
        lines = processing.segments(for: episodeId)
    }
}
