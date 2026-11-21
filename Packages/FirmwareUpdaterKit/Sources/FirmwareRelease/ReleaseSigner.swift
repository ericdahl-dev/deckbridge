import CryptoKit
import Foundation
import FirmwareCatalog
import FirmwareModel

/// A release signing key (ADR 0012). Only the maintainer's signing step holds one; the app holds `TrustedKey`s.
public struct SigningKey: Sendable {
    public let id: String
    let secret: Curve25519.Signing.PrivateKey

    public static func generate(id: String) -> SigningKey { SigningKey(id: id, secret: Curve25519.Signing.PrivateKey()) }

    public var trusted: TrustedKey { try! TrustedKey(id: id, publicKey: secret.publicKey.rawRepresentation) }

    /// The Ed25519 signature over exactly these manifest bytes.
    public func sign(_ manifest: Data) throws -> Data { try secret.signature(for: manifest) }
}

/// Writes a release's manifest from the folder CI's draft holds (catalog.json and the files it names).
public enum ReleaseSigner {
    /// The manifest's bytes, to sign as they are: the catalog, then each file present with its device, version, size and
    /// SHA-256. A panel build listed without its image is history and gets no file entry.
    public static func manifest(for folder: URL, keyID: String, lowestAllowedPanel: FirmwareVersion) throws -> Data {
        _ = try Catalog(directory: folder)
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "catalog.json"))) as? [String: Any] ?? [:]
        var files: [[String: Any]] = []
        func add(_ name: String, device: String, version: String) throws {
            let url = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
            let data = try Data(contentsOf: url)
            files.append(["name": name, "device": device, "version": version, "size": data.count, "sha256": sha256Hex(data)])
        }
        for panel in catalog["panel"] as? [[String: Any]] ?? [] {
            try add(panel["image"] as? String ?? "", device: "deck-panel", version: panel["version"] as? String ?? "")
        }
        for set in catalog["lc6000"] as? [[String: Any]] ?? [] {
            for entry in set["entries"] as? [[String: Any]] ?? [] {
                let chip = entry["chip"] as? String ?? ""
                try add(entry["file"] as? String ?? "", device: "lc6000-\(chip)", version: set[chip] as? String ?? "")
            }
        }
        let manifest: [String: Any] = [
            "format": 1,
            "key": keyID,
            "lowest_allowed": ["deck-panel": lowestAllowedPanel.description],
            "catalog": catalog,
            "files": files,
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
    }
}
