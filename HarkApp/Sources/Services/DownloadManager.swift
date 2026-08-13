import Foundation
import GRDB

/// Episode audio downloads. P1 uses an in-process session with per-episode progress; the upgrade
/// path to a background URLSession (survives app termination) is isolated behind this type.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var progress: [String: Double] = [:]   // episodeId → 0…1

    private let db = AppDatabase.shared
    private var tasks: [String: URLSessionDownloadTask] = [:]

    func isDownloading(_ episodeId: String) -> Bool { tasks[episodeId] != nil }

    func download(_ episode: Episode) {
        guard tasks[episode.id] == nil, let url = URL(string: episode.audioURL) else { return }
        setState(.downloading, for: episode.id, filename: nil)
        progress[episode.id] = 0

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            Task { @MainActor [weak self] in
                self?.finish(episodeId: episode.id, tempURL: tempURL, response: response, error: error)
            }
        }
        tasks[episode.id] = task

        // Observe fractionCompleted on the task's progress (KVO-free polling keeps this simple).
        let episodeId = episode.id
        Task { @MainActor [weak self] in
            while let self, let t = self.tasks[episodeId] {
                self.progress[episodeId] = t.progress.fractionCompleted
                if t.state == .completed || t.state == .canceling { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        task.resume()
    }

    func cancel(_ episodeId: String) {
        tasks[episodeId]?.cancel()
        tasks[episodeId] = nil
        progress[episodeId] = nil
        setState(.none, for: episodeId, filename: nil)
    }

    func delete(_ episode: Episode) {
        if let filename = episode.localFilename {
            try? FileManager.default.removeItem(at: AppDatabase.audioDirectory.appendingPathComponent(filename))
        }
        setState(.none, for: episode.id, filename: nil)
    }

    static func localURL(for episode: Episode) -> URL? {
        guard let filename = episode.localFilename else { return nil }
        let url = AppDatabase.audioDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func finish(episodeId: String, tempURL: URL?, response: URLResponse?, error: Error?) {
        tasks[episodeId] = nil
        progress[episodeId] = nil
        guard error == nil, let tempURL else {
            setState(.failed, for: episodeId, filename: nil)
            return
        }
        let ext = (response?.suggestedFilename as NSString?)?.pathExtension
        let filename = episodeId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            + "." + ((ext?.isEmpty == false ? ext! : "mp3"))
        let dest = AppDatabase.audioDirectory.appendingPathComponent(filename)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            setState(.downloaded, for: episodeId, filename: filename)
        } catch {
            setState(.failed, for: episodeId, filename: nil)
        }
    }

    private func setState(_ state: Episode.DownloadState, for episodeId: String, filename: String?) {
        try? db.dbQueue.write { db in
            if var ep = try Episode.fetchOne(db, key: episodeId) {
                ep.downloadState = state.rawValue
                ep.localFilename = filename
                try ep.save(db)
            }
        }
    }
}
