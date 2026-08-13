import SwiftUI
import GRDB

@main
struct HarkApp: App {
    @StateObject private var subscriptions = SubscriptionStore()
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var processing = ProcessingService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(subscriptions)
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(processing)
        }
    }
}

/// Four tabs (PRD §8.2) + persistent mini player + full-screen player sheet.
struct RootView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var subscriptions: SubscriptionStore
    @State private var showPlayer = false

    var body: some View {
        content
            .task { await debugSeedIfRequested() }
    }

    /// DEBUG-only harness hook: HARK_SEED_FEED=<rss url> subscribes on launch;
    /// HARK_AUTOPLAY=1 then plays the newest episode — lets the sim demo run hands-free.
    private func debugSeedIfRequested() async {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let feed = env["HARK_SEED_FEED"] else { return }
        await subscriptions.subscribe(feedURL: feed)
        if env["HARK_AUTOPLAY"] == "1" {
            let episode = try? await AppDatabase.shared.dbQueue.read { db in
            try Episode.order(Column("publishedAt").desc).fetchOne(db)
        }
            if let episode { player.play(episode) }
        }
        #endif
    }

    private var content: some View {
        TabView {
            Tab("Home", systemImage: "house") { HomeView(showPlayer: $showPlayer) }
            Tab("Discover", systemImage: "magnifyingglass") { DiscoverView() }
            Tab("Snips", systemImage: "scissors") { SnipsView() }
            Tab("You", systemImage: "person") { YouView() }
        }
        // The system mini-player slot: floats ABOVE the tab bar instead of covering it (a bottom
        // safeAreaInset overlaps iOS 26's floating tab bar).
        .tabViewBottomAccessory {
            if player.currentEpisode != nil {
                MiniPlayerBar { showPlayer = true }
            }
        }
        .sheet(isPresented: $showPlayer) { PlayerView() }
        .overlay(alignment: .top) {
            if let toast = player.snipToastText {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 4)
            }
        }
        .animation(.snappy, value: player.snipToastText)
    }
}
