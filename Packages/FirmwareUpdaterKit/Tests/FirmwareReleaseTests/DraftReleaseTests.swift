import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel
import FirmwareRelease

let scripts = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts").standardized

/// CI's draft (#703), signed by the maintainer's step, is a release the app takes: release_draft.py, ReleaseSigner and
/// ReleaseFetcher agree on the layout end to end. A test key; python3 runs the real script.
@Test func aDraftCIMakesSignedByTheReleaseStepIsAcceptedByTheApp() async throws {
    let repoCatalog = temporaryFolder()
    try FileManager.default.createDirectory(at: repoCatalog.appending(path: "lc6000"), withIntermediateDirectories: true)
    try Data("0x0800BDA4 0f28 1028\n".utf8).write(to: repoCatalog.appending(path: "lc6000/wd.patch"))
    try Data(#"""
    { "panel": [{ "version": "1.0.0", "sha": "aaaaaaa", "image": "panel/deck-panel-1.0.0-aaaaaaa.bin" }],
      "lc6000": [{ "wd": "00.50", "tp": "00.31", "entries": [{ "kind": "patch", "chip": "wd", "file": "lc6000/wd.patch" }] }] }
    """#.utf8).write(to: repoCatalog.appending(path: "catalog.json"))
    let work = temporaryFolder()
    try Data("1.1.0\n".utf8).write(to: work.appending(path: "VERSION"))
    try panelImage("1.1.0").write(to: work.appending(path: "firmware.bin"))
    let draft = work.appending(path: "draft")

    let python = Process()
    python.executableURL = URL(filePath: "/usr/bin/env")
    python.arguments = ["python3", "-I", scripts.appending(path: "release_draft.py").path(percentEncoded: false),
                        "--tag", "deck-panel-v1.1.0", "--version-file", work.appending(path: "VERSION").path(percentEncoded: false),
                        "--image", work.appending(path: "firmware.bin").path(percentEncoded: false), "--sha", "ddddddd",
                        "--catalog", repoCatalog.path(percentEncoded: false), "--out", draft.path(percentEncoded: false)]
    try python.run()
    python.waitUntilExit()
    try #require(python.terminationStatus == 0)

    let key = SigningKey.generate(id: "primary")
    let manifest = try ReleaseSigner.manifest(for: draft, keyID: key.id, lowestAllowedPanel: FirmwareVersion("1.0.0")!)
    var files: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: draft.path(percentEncoded: false)) {
        files[name] = try Data(contentsOf: draft.appending(path: name))
    }
    let feed = FakeFeed(manifest: manifest, signature: try key.sign(manifest), files: files)
    let outcome = await ReleaseFetcher(feed: feed, trusting: [key.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa", withPatchSet: true))
    #expect(outcome.refusal == nil)
    #expect(outcome.catalog.newestPanel()?.sha == "ddddddd")
    #expect(outcome.catalog.offer(for: PanelBuild(sha: "aaaaaaa")) == .update(try #require(outcome.catalog.newestPanel())))
}
