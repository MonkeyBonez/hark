import Foundation
import AVFoundation
import MediaPlayer
import GRDB

/// The transport core: AVPlayer + background audio session + lock-screen commands + the persisted
/// queue. P1's "thread of steel" — everything else hangs off this working reliably.
///
/// Snip capture (PRD §6, §8.4): `captureSnip()` stores a raw trailing time window instantly —
/// no transcript, no AI — wired to both the in-app pill and the lock-screen bookmark command.
@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var currentPodcast: Podcast?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1.0 { didSet { applyRate() } }
    @Published var snipToastText: String?

    private let player = AVPlayer()
    private let db = AppDatabase.shared
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastPersist = Date.distantPast

    /// The window a lock-screen snip captures: "what I just heard", boundary re-snap comes in P3.
    private let snipTrailingSeconds: Double = 30

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        installTimeObserver()
    }

    // MARK: Transport

    func play(_ episode: Episode, resume: Bool = true) {
        persistPosition(force: true)   // save the outgoing episode's position first

        let url = DownloadManager.localURL(for: episode) ?? URL(string: episode.audioURL)
        guard let url else { return }

        currentEpisode = episode
        currentPodcast = try? db.dbQueue.read { try Podcast.fetchOne($0, key: episode.podcastFeedURL) }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        if endObserver == nil {
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.episodeFinished() }
            }
        }

        if resume, episode.playbackPositionSeconds > 5 {
            player.seek(to: CMTime(seconds: episode.playbackPositionSeconds, preferredTimescale: 600))
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
        duration = episode.durationSeconds ?? 0
        markPlayed(episode)
        updateNowPlaying()

        // Transcript-first (PRD §9.5): start — or resume — chunked transcription at the playhead
        // so the live transcript and snip text light up within seconds. No-op if fully covered.
        if DownloadManager.localURL(for: episode) != nil {
            ProcessingService.shared.transcribe(episode)
        }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        player.pause()
        isPlaying = false
        persistPosition(force: true)
        updateNowPlaying()
    }

    func resume() {
        guard player.currentItem != nil else {
            if let ep = currentEpisode { play(ep) }
            return
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func skip(_ seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : .greatestFiniteMagnitude))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
        updateNowPlaying()
    }

    private func applyRate() {
        if isPlaying { player.rate = rate }
        updateNowPlaying()
    }

    // MARK: Queue (persisted, PRD §9.4 PlayQueue)

    func queuedEpisodes() -> [Episode] {
        (try? db.dbQueue.read { db in
            let items = try PlayQueueItem.order(Column("position")).fetchAll(db)
            return try items.compactMap { try Episode.fetchOne(db, key: $0.episodeId) }
        }) ?? []
    }

    func enqueue(_ episode: Episode) {
        try? db.dbQueue.write { db in
            let maxPos = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM playQueue") ?? 0
            try PlayQueueItem(episodeId: episode.id, position: maxPos + 1).save(db)
        }
    }

    func removeFromQueue(_ episodeId: String) {
        try? db.dbQueue.write { db in _ = try PlayQueueItem.deleteOne(db, key: episodeId) }
    }

    private func episodeFinished() {
        if let ep = currentEpisode {
            try? db.dbQueue.write { db in
                if var e = try Episode.fetchOne(db, key: ep.id) {
                    e.finished = true
                    e.playbackPositionSeconds = 0
                    try e.save(db)
                }
            }
        }
        // Auto-advance: pop the queue head.
        let queue = queuedEpisodes()
        if let next = queue.first {
            removeFromQueue(next.id)
            play(next, resume: false)
        } else {
            isPlaying = false
        }
    }

    // MARK: Snip capture (the P1 exit-demo feature)

    func captureSnip() {
        guard let episode = currentEpisode else { return }
        let end = Int(currentTime * 1000)
        let start = max(0, end - Int(snipTrailingSeconds * 1000))
        let snip = Snip(id: UUID().uuidString, episodeId: episode.id,
                        startMs: start, endMs: end, createdAt: Date(),
                        starred: false, state: "captured", title: nil,
                        category: nil, takeawaysJSON: nil)
        try? db.dbQueue.write { try snip.save($0) }
        // Title/categorize it right away if the transcript already covers this window.
        ProcessingService.shared.enrichPendingSnips()
        snipToastText = "Snip saved — \(Self.clock(start)) to \(Self.clock(end))"
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.snipToastText = nil
        }
    }

    // MARK: Session / remote commands / now playing

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(30) }; return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }; return .success
        }
        // The remote-command snip gesture (PRD §9.1: semantic commands only). Bookmark is the
        // semantically honest choice; the binding becomes a setting in §8.8.
        center.bookmarkCommand.isEnabled = true
        center.bookmarkCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.captureSnip() }; return .success
        }
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds
                if let item = self.player.currentItem, item.duration.isNumeric {
                    self.duration = item.duration.seconds
                }
                self.persistPosition()
            }
        }
    }

    /// Persist position at most every 5s while playing (and on pause/switch with force).
    private func persistPosition(force: Bool = false) {
        guard let ep = currentEpisode, currentTime > 0 else { return }
        guard force || Date().timeIntervalSince(lastPersist) > 5 else { return }
        lastPersist = Date()
        let position = currentTime
        try? db.dbQueue.write { db in
            if var e = try Episode.fetchOne(db, key: ep.id) {
                e.playbackPositionSeconds = position
                e.lastPlayedAt = Date()
                try e.save(db)
            }
        }
    }

    private func markPlayed(_ episode: Episode) {
        try? db.dbQueue.write { db in
            if var e = try Episode.fetchOne(db, key: episode.id) {
                e.lastPlayedAt = Date()
                try e.save(db)
            }
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentEpisode?.title ?? "",
            MPMediaItemPropertyArtist: currentPodcast?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    static func clock(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
