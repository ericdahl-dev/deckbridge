import Foundation
import FirmwareModel

/// A deck panel firmware image the app carries: its version, the build (git SHA) it was made from, and the file.
public struct PanelFirmware: Sendable, Hashable {
    public let version: FirmwareVersion
    public let sha: String
    public let image: URL
}

public enum CatalogError: Error, Equatable {
    case badVersion(String)
    case notAPatchDescription(String)
    case unnamedFile(String)
    case missingBuiltIn
    case outsideFolder(String)
}

/// The firmware the app ships with, read from a folder holding `catalog.json` and the files it names. No network.
public struct Catalog: Sendable {
    private let panel: [PanelFirmware]
    private let lc6000: [LC6000PatchSet]

    public init(directory: URL) throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: directory.appending(path: "catalog.json")))
        let names = file.panel.map(\.image) + file.lc6000.flatMap { $0.entries.flatMap { [$0.file] + [$0.record].compactMap { $0 } } }
        if let outside = names.first(where: { !Self.staysInside($0) }) { throw CatalogError.outsideFolder(outside) }
        panel = try file.panel.map { entry in
            guard let version = FirmwareVersion(entry.version) else { throw CatalogError.badVersion(entry.version) }
            return PanelFirmware(version: version, sha: entry.sha, image: directory.appending(path: entry.image))
        }
        lc6000 = try file.lc6000.map { set in
            try LC6000PatchSet(
                firmware: LC6000Firmware(wd: set.wd, tp: set.tp),
                entries: try set.entries.map { entry in
                    let url = directory.appending(path: entry.file)
                    switch entry.kind {
                    case .patch:
                        guard let edits = PatchDescription.edits(try Data(contentsOf: url)) else {
                            throw CatalogError.notAPatchDescription(entry.file)
                        }
                        return LC6000Entry(kind: .patch, chip: entry.chip, file: url, edits: edits)
                    case .block:
                        return LC6000Entry(kind: .block, chip: entry.chip, file: url)
                    }
                },
                blocks: Self.ownBlocks(in: set.entries, directory: directory))
        }
        let named = Set(["catalog.json"] + names)
        if let stray = try Self.files(in: directory).first(where: { !named.contains($0) }) {
            throw CatalogError.unnamedFile(stray)
        }
    }

    /// Block A and block B, when the set carries them, with the commit their build record names.
    private static func ownBlocks(in entries: [File.Entry], directory: URL) throws -> OwnBlocks? {
        let blocks = entries.filter { $0.kind == .block }
        guard let a = blocks.first(where: { $0.part == "a" }), let b = blocks.first(where: { $0.part == "b" }),
              let recordName = a.record else { return nil }
        let record = try JSONDecoder().decode(BuildRecord.self, from: Data(contentsOf: directory.appending(path: recordName)))
        return OwnBlocks(a: directory.appending(path: a.file), b: directory.appending(path: b.file), commit: record.commit)
    }

    private struct BuildRecord: Decodable {
        let commit: String
    }

    /// A plain relative path inside a folder: no leading "/", no "." or ".." parts, no empty parts, no backslashes.
    public static func staysInside(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.contains("\\") && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Every file under `directory`, as paths relative to it (Finder's .DS_Store aside).
    private static func files(in directory: URL) throws -> [String] {
        let root = directory.standardizedFileURL.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return try walk.compactMap { item in
            let url = (item as! URL).standardizedFileURL
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  url.lastPathComponent != ".DS_Store" else { return nil }
            return String(url.path(percentEncoded: false).dropFirst(prefix.count))
        }
    }

    /// The SHA of every panel build the catalog lists, carried or not.
    public var listedPanelSHAs: [String] { panel.map(\.sha) }

    /// The stock firmware pairs the catalog has an LC6000 patch set for.
    public var patchSetFirmwares: [LC6000Firmware] { lc6000.map(\.firmware) }

    /// The highest panel version whose image the app carries, or nil if it carries none. Entries without their
    /// image are builds shipped before: they still tell an older panel from an unknown one.
    public func newestPanel() -> PanelFirmware? {
        panel.filter { FileManager.default.fileExists(atPath: $0.image.path(percentEncoded: false)) }
            .max { $0.version < $1.version }
    }

    private struct File: Decodable {
        struct Panel: Decodable { let version: String; let sha: String; let image: String }
        struct Set: Decodable { let wd: String; let tp: String; let entries: [Entry] }
        struct Entry: Decodable {
            let kind: LC6000Entry.Kind
            let chip: Chip
            let file: String
            /// Blocks only: "a" or "b", and the build record `make arm` wrote beside them.
            var part: String? = nil
            var record: String? = nil
        }
        let panel: [Panel]
        let lc6000: [Set]
    }
}

/// What the app offers a deck panel.
public enum PanelOffer: Sendable, Hashable {
    /// The panel runs an older build the app shipped; this is newer.
    case update(PanelFirmware)
    /// The panel runs the newest build.
    case upToDate
    /// The panel runs a build the app doesn't know (a dev build, or newer than the app): offered with a note.
    case unknownBuild(PanelFirmware)
    /// The app carries no panel firmware.
    case nothing
}

extension Catalog {
    public func offer(for build: PanelBuild) -> PanelOffer {
        guard let newest = newestPanel() else { return .nothing }
        // A panel that reports its version (#695) is judged by it; the SHA list is for panels that report only a SHA.
        if let version = build.version { return version < newest.version ? .update(newest) : .upToDate }
        guard let shipped = panel.first(where: { Self.sameBuild($0.sha, build.sha) }) else { return .unknownBuild(newest) }
        return shipped.version < newest.version ? .update(newest) : .upToDate
    }

    /// Short and long forms of one SHA name the same build: the shorter must start the longer. Only plain hex SHAs
    /// match, so a "<sha>-dirty" build (uncommitted changes) is never the shipped one.
    static func sameBuild(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        guard [a, b].allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }) else { return false }
        return a.count <= b.count ? b.hasPrefix(a) : a.hasPrefix(b)
    }
}

public enum Chip: String, Sendable, Hashable, Decodable { case wd, tp }

/// One thing the app applies to an LC6000 chip: a patch description against Denon's firmware, or a block of this
/// repo's own code (#696).
public struct LC6000Entry: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Decodable {
        /// Addresses and the few bytes replaced at each, for one stock firmware version. Never a vendor image.
        case patch
        /// Block A or block B of the drawn jog display, built from this repo's sources by `make arm`.
        case block
    }

    public let kind: Kind
    public let chip: Chip
    public let file: URL
    public var edits: [PatchEdit] = []
}

/// One line of a patch description: at `address`, the bytes `old` become `new`.
public struct PatchEdit: Sendable, Hashable {
    public let address: UInt32
    public let old: [UInt8]
    public let new: [UInt8]

    public init(address: UInt32, old: [UInt8], new: [UInt8]) {
        self.address = address
        self.old = old
        self.new = new
    }
}

/// The patches tested together on one pair of stock firmware versions.
public struct LC6000PatchSet: Sendable, Hashable {
    public let firmware: LC6000Firmware
    public let entries: [LC6000Entry]
    /// The drawn jog display's own code, when the set carries it.
    public var blocks: OwnBlocks? = nil
}

/// Block A (the wd padding) and block B (the upper flash), from one build of this repo.
public struct OwnBlocks: Sendable, Hashable {
    public let a: URL
    public let b: URL
    /// The commit `make arm` built them from, as its build record says.
    public let commit: String
}

extension Catalog {
    /// The patch set tested on exactly these firmware versions, or nil if none fits.
    public func patchSet(for firmware: LC6000Firmware) -> LC6000PatchSet? {
        lc6000.first { $0.firmware == firmware }
    }
}

extension Catalog {
    /// The catalog the app ships with, from its own resources. Looked up by name: where SwiftPM puts a copied folder
    /// differs between a flat bundle and a macOS one.
    public static func builtIn() throws -> Catalog {
        guard let folder = Bundle.module.url(forResource: "Catalog", withExtension: nil) else {
            throw CatalogError.missingBuiltIn
        }
        return try Catalog(directory: folder)
    }
}
