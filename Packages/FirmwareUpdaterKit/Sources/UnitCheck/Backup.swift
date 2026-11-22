import Foundation

public enum BackupError: Error, Equatable {
    case readsDiffer
    case insideARepo
}

extension BackupError {
    public var reason: String {
        switch self {
        case .readsDiffer: "The two reads of the chip differ, so no backup was saved. Power the LC6000 off and on, then try again."
        case .insideARepo: "That folder is inside a git repository. Pick a folder outside any repository, so the backup is never committed."
        }
    }
}

/// The backup (#692): a chip read twice and compared, saved only when both reads match, in the folder the owner
/// picked, never inside a git repository. It stays on the Mac.
public enum Backup {
    /// The files, named by chip and `stamp` only: no serial number.
    public static func make(_ kind: ChipKind, reader: DFUReader, into folder: URL, stamp: String) async throws -> [URL] {
        try await reading(kind, reader: reader, into: folder, stamp: stamp).files
    }

    /// The backup and the read it saved.
    static func reading(_ kind: ChipKind, reader: DFUReader, into folder: URL, stamp: String) async throws
        -> (read: ChipRead, files: [URL]) {
        if insideARepo(folder) { throw BackupError.insideARepo }
        let first = try await ChipRead.read(kind, from: reader)
        let second = try await ChipRead.read(kind, from: reader)
        guard first == second else { throw BackupError.readsDiffer }
        let chip = kind == .display ? "wd" : "tp"
        let files = [
            (folder.appendingPathComponent("lc6000-\(chip)-settings-\(stamp).bin"), first.settings),
            (folder.appendingPathComponent("lc6000-\(chip)-app-\(stamp).bin"), first.app),
        ]
        for (url, bytes) in files { try Data(bytes).write(to: url, options: .withoutOverwriting) }
        return (first, files.map(\.0))
    }

    /// The folder or any folder above it holds `.git`.
    static func insideARepo(_ folder: URL) -> Bool {
        var path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        while true {
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return true }
            if path == "/" || path.isEmpty { return false }
            path = (path as NSString).deletingLastPathComponent
        }
    }
}
