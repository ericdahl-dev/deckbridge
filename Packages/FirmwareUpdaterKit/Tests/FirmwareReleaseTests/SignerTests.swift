import CryptoKit
import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel
import FirmwareRelease

/// A release folder as `gh release download` gives it: the catalog plus the files it names, flat, since a GitHub
/// release asset's name can't hold a "/".
func releaseFolder(panelVersion: String, sha: String) throws -> URL {
    let folder = temporaryFolder()
    let image = "deck-panel-\(panelVersion)-\(sha).bin"
    try panelImage(panelVersion).write(to: folder.appending(path: image))
    try Data("# test\n0x0800BDA4 0f28 1028\n".utf8).write(to: folder.appending(path: "wd.patch"))
    let json = #"""
    { "panel": [{ "version": "1.0.0", "sha": "aaaaaaa", "image": "deck-panel-1.0.0-aaaaaaa.bin" },
                { "version": "\#(panelVersion)", "sha": "\#(sha)", "image": "\#(image)" }],
      "lc6000": [{ "wd": "00.50", "tp": "00.31", "entries": [{ "kind": "patch", "chip": "wd", "file": "wd.patch" }] }] }
    """#
    try Data(json.utf8).write(to: folder.appending(path: "catalog.json"))
    return folder
}

/// The feed GitHub would serve once the signing step has uploaded the manifest and its signature next to the files.
func feed(serving folder: URL, manifest: Data, signature: Data) throws -> FakeFeed {
    var files: [String: Data] = [:]
    for name in ["deck-panel-1.1.0-ddddddd.bin", "wd.patch"] {
        files[name] = try Data(contentsOf: folder.appending(path: name))
    }
    return FakeFeed(manifest: manifest, signature: signature, files: files)
}

@Test func whatTheSigningStepWritesIsAcceptedByTheApp() async throws {
    let key = SigningKey.generate(id: "primary")
    let folder = try releaseFolder(panelVersion: "1.1.0", sha: "ddddddd")
    let manifest = try ReleaseSigner.manifest(for: folder, keyID: key.id, lowestAllowedPanel: FirmwareVersion("1.0.0")!)
    let signature = try key.sign(manifest)
    let outcome = await ReleaseFetcher(feed: try feed(serving: folder, manifest: manifest, signature: signature),
                                       trusting: [key.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == nil)
    #expect(outcome.catalog.newestPanel()?.version == FirmwareVersion("1.1.0"))
    #expect(outcome.catalog.patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31")) != nil)
    #expect(outcome.lowestAllowedPanel == FirmwareVersion("1.0.0"))
}

/// The signing step checks the release with the app's own rules before signing, so the maintainer can't sign a
/// release the app would refuse (an LC6000 file that isn't a patch description, a file the catalog doesn't name).
@Test func theSigningStepRefusesAFolderTheAppWouldNotLoad() throws {
    let folder = try releaseFolder(panelVersion: "1.1.0", sha: "ddddddd")
    try Data(repeating: 0, count: 4096).write(to: folder.appending(path: "stray.bin"))
    #expect(throws: CatalogError.unnamedFile("stray.bin")) {
        try ReleaseSigner.manifest(for: folder, keyID: "primary", lowestAllowedPanel: FirmwareVersion("1.0.0")!)
    }
}

/// A release whose panel build carries its bootloader and partition table (#687): the manifest signs both, under
/// devices of their own, so the panel's own reader (#690), which takes one "deck-panel" image, skips them; and the app
/// fetches and loads them.
@Test func aReleaseWithThePanelsBootPartsSignsThemAndTheAppLoadsThem() async throws {
    let key = SigningKey.generate(id: "primary")
    let folder = temporaryFolder()
    let image = "deck-panel-1.1.0-ddddddd.bin", loader = "deck-panel-1.1.0-ddddddd-bootloader.bin"
    let table = "deck-panel-1.1.0-ddddddd-partitions.bin"
    try panelImage("1.1.0").write(to: folder.appending(path: image))
    try (Data([0xE9]) + Data(repeating: 0x22, count: 64)).write(to: folder.appending(path: loader))
    var rows = Data([0xAA, 0x50, 0x01, 0x02]) + Data(repeating: 0, count: 28)
    rows += Data([0xEB, 0xEB]) + Data(repeating: 0xFF, count: 14) + Data(Insecure.MD5.hash(data: rows))
    try (rows + Data(repeating: 0xFF, count: 3072 - rows.count)).write(to: folder.appending(path: table))
    let json = #"{"panel": [{"version": "1.0.0", "sha": "aaaaaaa", "image": "deck-panel-1.0.0-aaaaaaa.bin"}, {"version": "1.1.0", "sha": "ddddddd", "image": "\#(image)", "bootloader": "\#(loader)", "partitions": "\#(table)"}], "lc6000": []}"#
    try Data(json.utf8).write(to: folder.appending(path: "catalog.json"))

    let manifest = try ReleaseSigner.manifest(for: folder, keyID: key.id, lowestAllowedPanel: FirmwareVersion("1.0.0")!)
    let listed = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
    let files = (listed?["files"] as? [[String: Any]] ?? []).map { "\($0["device"] ?? "") \($0["name"] ?? "")" }
    #expect(files == ["deck-panel \(image)", "deck-panel-bootloader \(loader)", "deck-panel-partitions \(table)"])

    var served: [String: Data] = [:]
    for name in [image, loader, table] { served[name] = try Data(contentsOf: folder.appending(path: name)) }
    let outcome = await ReleaseFetcher(feed: FakeFeed(manifest: manifest, signature: try key.sign(manifest), files: served),
                                       trusting: [key.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == nil)
    #expect(outcome.catalog.newestPanel()?.bootParts != nil)
}
