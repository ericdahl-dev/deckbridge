import DeviceFinder
import Foundation

/// The log file the owner can send: ~/Library/Logs/FirmwareUpdater/updater.log. Only what the finder logs goes in,
/// and the finder leaves out serial numbers, MAC addresses and Wi-Fi details (#685).
final class FileLog: LogSink, @unchecked Sendable {
    static let shared = FileLog()

    private let lock = NSLock()
    private let url: URL
    private let stamp = ISO8601DateFormatter()

    private init() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/FirmwareUpdater")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appending(path: "updater.log")
    }

    func log(_ line: String) {
        lock.withLock {
            let entry = Data((stamp.string(from: Date()) + " " + line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entry)
            } else {
                try? entry.write(to: url)
            }
        }
    }
}
