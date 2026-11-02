import SwiftUI
import GRDB

struct FindView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Binding var showPlayer: Bool

    @State private var query = ""
    @State private var state: SearchState = .prompt
    @State private var openingID: String?
    @State private var destinationError: String?

    private enum SearchState {
        case prompt, invalid, tooLong, loading, results(MomentSearchResults), failed
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Find")
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search transcripts and snips")
                .task(id: query) { await observe(query) }
                .alert("Moment unavailable", isPresented: Binding(
                    get: { destinationError != nil },
                    set: { if !$0 { destinationError = nil } }
                )) {
                    Button("OK") { destinationError = nil }
                } message: {
                    Text(destinationError ?? "")
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .prompt:
            ContentUnavailableView(
                "Find a moment", systemImage: "text.magnifyingglass",
                description: Text("Search saved transcript lines and snips on this device.")
            )
        case .invalid:
            ContentUnavailableView(
                "Enter words or numbers", systemImage: "text.magnifyingglass",
                description: Text("Punctuation alone can't be searched.")
            )
        case .tooLong:
            ContentUnavailableView(
                "Search is too long", systemImage: "text.magnifyingglass",
                description: Text("Use 200 characters or fewer.")
            )
        case .loading:
            ProgressView("Searching on this device…")
        case .failed:
            ContentUnavailableView(
                "Search unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Couldn't read the local search index. Try again.")
            )
        case .results(let results):
            if results.isEmpty {
                ContentUnavailableView(
                    "No moments found", systemImage: "magnifyingglass",
                    description: Text("Try fewer or different words. Each match is within one transcript line or snip.")
                )
                .accessibilityIdentifier("search.noResults")
            } else {
                List {
                    if !results.snips.isEmpty {
                        Section("Saved snips") {
                            ForEach(results.snips) { result in row(result) }
                        }
                    }
                    if !results.transcript.isEmpty {
                        Section("Transcript") {
                            ForEach(results.transcript) { result in row(result) }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func row(_ result: MomentSearchResult) -> some View {
        Button {
            Task { await open(result) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(result.kind == .snip ? "Snip" : "Transcript",
                          systemImage: result.kind == .snip ? "scissors" : "text.quote")
                    Spacer()
                    Text(PlayerEngine.clock(result.startMs)).monospacedDigit()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                if result.kind == .snip {
                    Text(result.title ?? "Saved snip").font(.subheadline.weight(.semibold))
                }
                if !result.excerpt.isEmpty {
                    Text(result.excerpt)
                        .font(.subheadline)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                }
                Text([result.podcastTitle, result.episodeTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(openingID != nil)
        .accessibilityIdentifier("search.\(result.kind.rawValue).\(result.recordID)")
        .accessibilityHint("Open the player at this saved time")
    }

    @MainActor private func observe(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { state = .prompt; return }
        guard trimmed.count <= MomentSearch.maximumQueryLength else { state = .tooLong; return }
        guard let pattern = MomentSearch.pattern(for: trimmed) else { state = .invalid; return }
        state = .loading
        do {
            try await Task.sleep(for: .milliseconds(150))
            for try await results in MomentSearch.observation(for: pattern)
                .values(in: AppDatabase.shared.dbQueue) {
                guard !Task.isCancelled else { return }
                state = .results(results)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
        }
    }

    @MainActor private func open(_ result: MomentSearchResult) async {
        guard openingID == nil else { return }
        openingID = result.id
        defer { openingID = nil }
        do {
            guard let destination = try await AppDatabase.shared.dbQueue.read({ db in
                try MomentSearch.destination(for: result, in: db)
            }) else {
                destinationError = "This transcript line or snip was changed or removed."
                return
            }
            if await player.playFromSearch(destination) { showPlayer = true }
        } catch {
            destinationError = "Couldn't read this saved moment. Try the search again."
        }
    }
}
