import CryptoKit
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
    /// A block whose bytes aren't the ones its build record names: A and B from different builds.
    case differentBuilds(String)
    /// Block A without block B, or B without A ("a" or "b" names the one missing).
    case missingBlock(String)
    /// A block entry that isn't shaped like block A or block B as this repo builds them.
    case notOurBlock(String)
    /// A known number (#692) that isn't a wd CRC ("0x" and 8 hex digits) or a tp SHA-256 (64 hex digits).
    case badNumber(String)
}

/// The firmware the app ships with, read from a folder holding `catalog.json` and the files it names. No network.
public struct Catalog: Sendable {
    private let panel: [PanelFirmware]
    private let lc6000: [LC6000PatchSet]
    public let knownNumbers: KnownNumbers

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
        knownNumbers = try Self.numbers(file.lc6000)
        let named = Set(["catalog.json"] + names)
        if let stray = try Self.files(in: directory).first(where: { !named.contains($0) }) {
            throw CatalogError.unnamedFile(stray)
        }
    }

    /// Block A and block B, when the set carries them, with the commit their build record names. Both or neither,
    /// and each must be the very bytes the record names, so the two are from one build.
    private static func ownBlocks(in entries: [File.Entry], directory: URL) throws -> OwnBlocks? {
        let blocks = entries.filter { $0.kind == .block }
        if blocks.isEmpty { return nil }
        guard let a = blocks.first(where: { $0.part == "a" }) else { throw CatalogError.missingBlock("a") }
        guard let b = blocks.first(where: { $0.part == "b" }) else { throw CatalogError.missingBlock("b") }
        guard let recordName = a.record, b.record == recordName else { throw CatalogError.differentBuilds(b.file) }
        let record = try JSONDecoder().decode(BuildRecord.self, from: Data(contentsOf: directory.appending(path: recordName)))
        for (entry, named) in [(a, record.block_a), (b, record.block_b)] {
            let bytes = try Data(contentsOf: directory.appending(path: entry.file))
            guard entry.part == "a" ? OwnBlockShape.isBlockA(bytes) : OwnBlockShape.isBlockB(bytes) else {
                throw CatalogError.notOurBlock(entry.file)
            }
            guard bytes.count == named.length, sha1(bytes) == named.sha1.lowercased() else {
                throw CatalogError.differentBuilds(entry.file)
            }
        }
        return OwnBlocks(a: directory.appending(path: a.file), b: directory.appending(path: b.file), commit: record.commit)
    }

    private static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What `make arm` writes beside the blocks (tools/lc6000-firmware/build_record.py): each block's sha1 and length.
    private struct BuildRecord: Decodable {
        struct Block: Decodable { let sha1: String; let length: Int }
        let commit: String
        let block_a: Block
        let block_b: Block
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

    /// The numbers the sets' stock firmware is known by (#692). A number that isn't one fails the load.
    private static func numbers(_ sets: [File.Set]) throws -> KnownNumbers {
        var display: [UInt32: String] = [:], topPanel: [String: String] = [:]
        for set in sets {
            guard let known = set.known else { continue }
            if let crc = known.wd_crc {
                guard crc.wholeMatch(of: /0x[0-9A-F]{8}/) != nil, let value = UInt32(crc.dropFirst(2), radix: 16) else {
                    throw CatalogError.badNumber(crc)
                }
                display[value] = set.wd
            }
            if let hash = known.tp_sha256 {
                guard hash.wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw CatalogError.badNumber(hash) }
                topPanel[hash] = set.tp
            }
        }
        return KnownNumbers(display: display, topPanel: topPanel)
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
        struct Set: Decodable { let wd: String; let tp: String; let entries: [Entry]; var known: Known? = nil }
        /// The numbers this set's stock firmware is known by (#692): "0x" and 8 hex digits; 64 hex digits.
        struct Known: Decodable { let wd_crc: String?; let tp_sha256: String? }
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

/// Numbers only, never firmware: the wd image's trailer CRC and the tp app area's SHA-256 (hex), each to its version.
public struct KnownNumbers: Sendable, Hashable {
    public let display: [UInt32: String]
    public let topPanel: [String: String]
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

extension CatalogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notOurBlock(let file): "\(file) is not one of DeckBridge's own blocks"
        default: nil
        }
    }
}

/// The shapes of block A and block B as `make arm` builds them (tools/lc6000-display-fw/arm): a check that a block
/// entry is this repo's code, not Denon's. Shape only; that the bytes are this repo's build is the release build's
/// job, which rebuilds them.
enum OwnBlockShape {
    /// Block A fills the wd padding, 0x0807DC00 up to 0x0807FFE0, and ends in its marker "DFW1" (arm/hook.h).
    static func isBlockA(_ bytes: Data) -> Bool {
        let a = [UInt8](bytes)
        return a.count == 9184 && word(a, 9180) == 0x3157_4644
    }

    /// Block B's header (arm/upper_header.py): marker "DFWB", version 4, its length (all of B, at most the upper
    /// flash's 512 KB), and zlib's CRC-32 of B from +16 to that length.
    static func isBlockB(_ bytes: Data) -> Bool {
        let b = [UInt8](bytes)
        guard b.count >= 28, b.count <= 0x80000, word(b, 0) == 0x4257_4644, word(b, 4) == 4,
              word(b, 8) == UInt32(b.count) else { return false }
        return crc32(b[16...]) == word(b, 12)
    }

    private static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[at + i]) << (8 * UInt32(i)) }
        return value
    }

    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

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
