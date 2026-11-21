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
