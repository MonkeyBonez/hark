import Foundation

enum PlaybackSource {
    /// The local URL has already been checked by DownloadManager.
    static func resolve(localURL: URL?, remoteURL: String) -> URL? {
        if let localURL { return localURL }
        guard let url = URL(string: remoteURL) else { return nil }
        if url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return url
        }
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
