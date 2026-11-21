import CryptoKit
import Foundation
import FirmwareCatalog
import FirmwareModel

/// Where releases are published: this project's GitHub releases, or a fake in tests.
public protocol ReleaseFeed: Sendable {
    /// The newest release's manifest and its signature, as published.
    func latest() async throws -> PublishedRelease
    /// One file of that release, by the name the manifest gives it.
    func file(_ name: String) async throws -> Data
}

public struct PublishedRelease: Sendable {
    public let manifest: Data
    public let signature: Data

    public init(manifest: Data, signature: Data) {
        self.manifest = manifest
        self.signature = signature
    }
}

/// Why a fetched release wasn't used. The built-in catalog stays in use whatever the reason.
public enum Refusal: Error, Sendable, Equatable {
    case badSignature
    /// The manifest isn't one: cut short, empty, or not JSON.
    case unreadableManifest
    /// Signed, by its own account, with a key the app doesn't trust.
    case unknownKey(String)
    /// A file whose size or SHA-256 differs from the manifest: altered, or cut short.
    case fileMismatch(String)
    /// A file name that would land outside the release's folder.
    case unsafeFileName(String)
    /// Checked and sound, but no newer than the firmware the app already carries.
    case notNewer
    /// The feed couldn't be reached, or a file couldn't be fetched.
    case unreachable
    /// Signed and intact, but not a catalog the app accepts (an LC6000 entry that isn't a patch description, say).
    case notACatalog(CatalogError)
    /// Signed and intact, but its catalog isn't in the shape the app reads.
    case unreadableCatalog
    /// The release couldn't be written to the app's cache folder.
    case couldNotStore
    /// It would drop something the built-in catalog carries: an LC6000 patch set, or a panel build shipped before.
    case dropsBuiltIn
    /// A manifest format this app doesn't read; a newer app is needed.
    case unknownFormat(Int)
}

public struct FetchOutcome: Sendable {
    /// The catalog to use: the fetched release if it passed every check, otherwise the built-in one.
    public let catalog: Catalog
    /// Why the fetched release wasn't used, or nil if it was.
    public var refusal: Refusal? = nil
    /// The lowest panel version the used release lets a panel go back to, or nil (the built-in catalog sets none).
    public var lowestAllowedPanel: FirmwareVersion? = nil

    public init(catalog: Catalog, refusal: Refusal? = nil, lowestAllowedPanel: FirmwareVersion? = nil) {
        self.catalog = catalog
        self.refusal = refusal
        self.lowestAllowedPanel = lowestAllowedPanel
    }
}

public struct ReleaseFetcher: Sendable {
    let feed: any ReleaseFeed
    let keys: [TrustedKey]
    let cache: URL

    public init(feed: any ReleaseFeed, trusting keys: [TrustedKey], cache: URL) {
        self.feed = feed
        self.keys = keys
        self.cache = cache
    }

    public func fetch(over builtIn: Catalog) async -> FetchOutcome {
        do {
            let (catalog, lowest) = try await fetched(over: builtIn)
            return FetchOutcome(catalog: catalog, lowestAllowedPanel: lowest)
        } catch let refusal as Refusal {
            return FetchOutcome(catalog: builtIn, refusal: refusal)
        } catch {
            return FetchOutcome(catalog: builtIn, refusal: .couldNotStore)
        }
    }

    private func fetched(over builtIn: Catalog) async throws -> (Catalog, FirmwareVersion?) {
        let published = try await reach { try await feed.latest() }
        // Nothing in the manifest is used before its signature checks out, except the name of the key to check it with.
        guard let claimed = try? JSONDecoder().decode(KeyName.self, from: published.manifest).key else {
            throw Refusal.unreadableManifest
        }
        guard let key = keys.first(where: { $0.id == claimed }) else { throw Refusal.unknownKey(claimed) }
        guard key.signed(published.manifest, published.signature) else { throw Refusal.badSignature }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: published.manifest) else {
            throw Refusal.unreadableManifest
        }
        guard manifest.format == 1 else { throw Refusal.unknownFormat(manifest.format) }
        if let unsafe = manifest.files.map(\.name).first(where: { !Catalog.staysInside($0) }) {
            throw Refusal.unsafeFileName(unsafe)
        }
        let folder = cache.appending(path: "fetched")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in manifest.files {
            let target = folder.appending(path: file.name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try await reach { try await feed.file(file.name) }
            guard data.count == file.size, sha256Hex(data) == file.sha256.lowercased() else {
                throw Refusal.fileMismatch(file.name)
            }
            try data.write(to: target)
        }
        try Manifest.catalogJSON(in: published.manifest).write(to: folder.appending(path: "catalog.json"))
        let catalog: Catalog
        do { catalog = try Catalog(directory: folder) }
        catch let error as CatalogError { throw Refusal.notACatalog(error) }
        catch { throw Refusal.unreadableCatalog }
        // Newer means a newer panel image than the app carries; LC6000 patch sets ride along with it.
        guard let offered = catalog.newestPanel()?.version,
              builtIn.newestPanel().map({ $0.version < offered }) ?? true else { throw Refusal.notNewer }
        guard Set(builtIn.listedPanelSHAs).isSubset(of: catalog.listedPanelSHAs),
              Set(builtIn.patchSetFirmwares).isSubset(of: catalog.patchSetFirmwares) else { throw Refusal.dropsBuiltIn }
        return (catalog, manifest.lowestAllowed["deck-panel"].flatMap(FirmwareVersion.init))
    }

    private struct KeyName: Decodable { let key: String }

    /// Any failure talking to the feed is the network's, whatever the feed threw.
    private func reach<T>(_ call: () async throws -> T) async throws -> T {
        do { return try await call() } catch { throw Refusal.unreachable }
    }

}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
