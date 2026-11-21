import CryptoKit
import Foundation
import FirmwareCatalog
import FirmwareRelease

/// A release feed in memory: what a GitHub release would serve. Files can be altered or cut short, or the network
/// made unreachable, to test each refusal.
final class FakeFeed: ReleaseFeed, @unchecked Sendable {
    var manifest: Data
    var signature: Data
    var files: [String: Data]
    var unreachable = false

    init(manifest: Data, signature: Data, files: [String: Data]) {
        self.manifest = manifest
        self.signature = signature
        self.files = files
    }

    func latest() async throws -> PublishedRelease {
        if unreachable { throw URLError(.notConnectedToInternet) }
        return PublishedRelease(manifest: manifest, signature: signature)
    }

    func file(_ name: String) async throws -> Data {
        if unreachable { throw URLError(.notConnectedToInternet) }
        guard let data = files[name] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

/// A key made for one test and dropped with it: never a real release key.
struct TestKey {
    let id: String
    let secret = Curve25519.Signing.PrivateKey()
    var trusted: TrustedKey { try! TrustedKey(id: id, publicKey: secret.publicKey.rawRepresentation) }
    func sign(_ bytes: Data) -> Data { try! secret.signature(for: bytes) }
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func panelImage(_ tag: String) -> Data { Data([0xE9]) + Data("deck panel image \(tag)".utf8) }

/// A release as the maintainer's signing step writes it: one panel image, listed in the catalog and in the files, after
/// the builds shipped before it (`history`, listed without images, as the repo's catalog.json keeps them).
func release(panelVersion: String, sha: String, signedBy key: TestKey, lowestAllowed: String = "1.0.0",
             name: String? = nil, wdPatch: Data? = nil, catalog: [String: Any]? = nil,
             history: [(version: String, sha: String)] = [("1.0.0", "aaaaaaa")], format: Int = 1) -> FakeFeed {
    let name = name ?? "panel/deck-panel-\(panelVersion)-\(sha).bin"
    let image = panelImage(panelVersion)
    var files: [String: Data] = [name: image]
    var listed: [[String: Any]] = [["name": name, "device": "deck-panel", "version": panelVersion, "size": image.count,
                                    "sha256": sha256Hex(image)]]
    var lc6000: [[String: Any]] = []
    if let wdPatch {
        let patch = "lc6000/wd-00.50.patch"
        files[patch] = wdPatch
        listed.append(["name": patch, "device": "lc6000-wd", "version": "00.50", "size": wdPatch.count, "sha256": sha256Hex(wdPatch)])
        lc6000 = [["wd": "00.50", "tp": "00.31", "entries": [["kind": "patch", "chip": "wd", "file": patch]]]]
    }
    let manifest: [String: Any] = [
        "format": format,
        "key": key.id,
        "lowest_allowed": ["deck-panel": lowestAllowed],
        "catalog": catalog ?? ["panel": history.map { ["version": $0.version, "sha": $0.sha, "image": "deck-panel-\($0.version)-\($0.sha).bin"] }
                                   + [["version": panelVersion, "sha": sha, "image": name]], "lc6000": lc6000],
        "files": listed,
    ]
    let bytes = try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    return FakeFeed(manifest: bytes, signature: key.sign(bytes), files: files)
}

/// The built-in catalog of an app that carries one panel image, in a fresh temporary folder.
func builtIn(panelVersion: String, sha: String, withPatchSet: Bool = false) throws -> Catalog {
    let folder = temporaryFolder()
    let name = "deck-panel-\(panelVersion)-\(sha).bin"
    try panelImage("built-in").write(to: folder.appending(path: name))
    var lc6000 = ""
    if withPatchSet {
        try Data("0x0800BDA4 0f28 1028\n".utf8).write(to: folder.appending(path: "wd.patch"))
        lc6000 = #"{ "wd": "00.50", "tp": "00.31", "entries": [{ "kind": "patch", "chip": "wd", "file": "wd.patch" }] }"#
    }
    let json = #"{ "panel": [{ "version": "\#(panelVersion)", "sha": "\#(sha)", "image": "\#(name)" }], "lc6000": [\#(lc6000)] }"#
    try Data(json.utf8).write(to: folder.appending(path: "catalog.json"))
    return try Catalog(directory: folder)
}

func temporaryFolder() -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "firmware-release-tests/\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}
