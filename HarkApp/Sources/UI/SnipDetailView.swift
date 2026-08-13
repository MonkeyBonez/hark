import SwiftUI
import GRDB

/// Snip detail (PRD §8.4): the full excerpt a snip covers, edited **through the transcript text
/// itself** — tap a surrounding line to include it, tap the first/last included line to trim it.
/// A snip stores only a raw time window (§9.4), so "including a line" just moves startMs/endMs to
/// that line's edges; the window stays contiguous and never empties.
struct SnipDetailView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var processing: ProcessingService
    @Environment(\.dismiss) private var dismiss
    let snip: Snip
    let episode: Episode
    var onChange: () -> Void

    @State private var lines: [TranscriptLine] = []
    /// What the DB currently holds — every write goes through this copy so a later write (e.g.
    /// starring) can never revert an earlier one (e.g. saved boundaries).
    @State private var persisted: Snip
    @State private var startMs: Int
    @State private var endMs: Int
    @State private var dirty = false
    /// How much transcript context to offer around the window, extended by Show earlier/later.
    @State private var padBeforeMs = 60_000
    @State private var padAfterMs = 60_000

    init(snip: Snip, episode: Episode, onChange: @escaping () -> Void = {}) {
        self.snip = snip
        self.episode = episode
        self.onChange = onChange
        _persisted = State(initialValue: snip)
        _startMs = State(initialValue: snip.startMs)
        _endMs = State(initialValue: snip.endMs)
    }

    /// Segments inside the current window, in order — the text the snip "contains".
    private var coveredLines: [TranscriptLine] {
        lines.filter { $0.endMs > startMs && $0.startMs < endMs }
    }

    private var coveredText: String {
        coveredLines.map(\.text).joined(separator: " ")
    }

    /// The window plus surrounding context — what the editor shows.
    private var contextLines: [TranscriptLine] {
        lines.filter { $0.endMs > startMs - padBeforeMs && $0.startMs < endMs + padAfterMs }
    }

    var body: some View {
        NavigationStack {
            List {
                if persisted.title != nil || !persisted.takeaways.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            if let title = persisted.title {
                                Text(title).font(.headline)
                            }
                            ForEach(persisted.takeaways, id: \.self) { takeaway in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(takeaway).font(.subheadline)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if lines.isEmpty {
                    Section("Excerpt") {
                        Text("No transcript here yet — it appears as this part of the episode is transcribed.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    editorSection
                }

                Section {
                    Button {
                        player.play(episode, resume: false)
                        player.seek(to: Double(startMs) / 1000)
                    } label: {
                        Label("Play from start", systemImage: "play.circle")
                    }
                }

                Section {
                    Button("Delete snip", role: .destructive) {
                        try? AppDatabase.shared.dbQueue.write { _ = try Snip.deleteOne($0, key: snip.id) }
                        onChange()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Snip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { toggleStar() } label: {
                        Image(systemName: persisted.starred ? "star.fill" : "star")
                            .foregroundStyle(.yellow)
                    }
                    Button("Save") { save() }.disabled(!dirty || endMs <= startMs)
                }
            }
        }
        .onAppear { lines = processing.segments(for: episode.id) }
        .task(id: processing.transcriptVersion) { lines = processing.segments(for: episode.id) }
    }

    /// The text-based boundary editor: highlighted lines are in the snip; dimmed lines around them
    /// are one tap from joining it.
    private var editorSection: some View {
        Section {
            Button {
                padBeforeMs += 90_000
            } label: {
                Label("Show earlier lines", systemImage: "chevron.up")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(contextLines) { line in
                let included = line.endMs > startMs && line.startMs < endMs
                Text(line.text)
                    .font(.subheadline)
                    .foregroundStyle(included ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(included ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(line) }
                    .listRowSeparator(.hidden)
            }
            Button {
                padAfterMs += 90_000
            } label: {
                Label("Show later lines", systemImage: "chevron.down")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Excerpt — tap lines to include or trim")
        } footer: {
            Text("\(PlayerEngine.clock(startMs)) – \(PlayerEngine.clock(endMs)) · \(PlayerEngine.clock(max(0, endMs - startMs))) long")
                .monospacedDigit()
        }
    }

    /// Tap outside the window → grow to that line. Tap the first/last included line → trim it off.
    /// Middle lines can't be removed (the window is contiguous), and the last line can't be — a
    /// snip never goes empty.
    private func toggle(_ line: TranscriptLine) {
        let included = line.endMs > startMs && line.startMs < endMs
        if !included {
            startMs = max(0, min(startMs, line.startMs))
            endMs = max(endMs, line.endMs)
        } else {
            let covered = coveredLines
            guard covered.count > 1 else { return }
            if line.id == covered.first?.id {
                startMs = covered[1].startMs
            } else if line.id == covered.last?.id {
                endMs = covered[covered.count - 2].endMs
            } else {
                return
            }
        }
        dirty = true
    }

    private func toggleStar() {
        persisted.starred.toggle()
        try? AppDatabase.shared.dbQueue.write { try persisted.save($0) }
        onChange()
    }

    private func save() {
        persisted.startMs = startMs
        persisted.endMs = endMs
        try? AppDatabase.shared.dbQueue.write { try persisted.save($0) }
        onChange()
        dismiss()
    }
}
