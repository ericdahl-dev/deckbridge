import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel
import FirmwareRelease

// What the app shows on launch (#704): its built-in catalog, the GitHub feed over HTTP, and the app's trusted keys,
// put together as the app does, from a fake GitHub.

/// A release as the signing step writes it, published on the fake GitHub: manifest.json, manifest.sig and its files
/// as the release's assets.
func publish(_ release: FakeFeed, on github: FakeGitHub) {
    let names = ["manifest.json", "manifest.sig"] + release.files.keys.sorted()
    github.answers[latestURL] = HTTPResponse(status: 200, body: releaseJSON(assets: names))
    serve("manifest.json", release.manifest, on: github)
    serve("manifest.sig", release.signature, on: github)
    for (name, bytes) in release.files { serve(name, bytes, on: github) }
}

@Test func withTheAppsKeysStillEmptyAWholeReleaseOffersTheBuiltInFirmwareAndSaysTheKeyIsUnknown() async throws {
    let github = FakeGitHub()
    publish(release(panelVersion: "1.1.0", sha: "bbbbbbb", signedBy: TestKey(id: "primary"), name: "deck-panel-1.1.0-bbbbbbb.bin"),
            on: github)
    let offer = await FirmwareOffer.fetch(http: github, over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"),
                                          cache: temporaryFolder())
    #expect(offer.source == "Firmware built into this app: deck panel 1.0.0")
    #expect(offer.reason == "The newest release is signed with a key this app doesn't trust yet, so the firmware built into this app is offered.")
}

@Test func gitHubTimingOutOffersTheBuiltInFirmwareAndSaysItCouldntBeReached() async throws {
    let github = FakeGitHub()
    github.timingOut = [latestURL]
    let offer = await FirmwareOffer.fetch(http: github, over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"),
                                          cache: temporaryFolder())
    #expect(offer.source == "Firmware built into this app: deck panel 1.0.0")
    #expect(offer.reason == "GitHub couldn't be reached, so the firmware built into this app is offered.")
}

@Test func aSoundReleaseOlderThanTheBuiltInOffersTheBuiltInFirmwareAndSaysSo() async throws {
    let key = TestKey(id: "primary")
    let github = FakeGitHub()
    publish(release(panelVersion: "0.9.0", sha: "ccccccc", signedBy: key, lowestAllowed: "0.9.0", name: "deck-panel-0.9.0-ccccccc.bin"),
            on: github)
    let offer = await FirmwareOffer.fetch(http: github, over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"),
                                          cache: temporaryFolder(), trusting: [key.trusted])
    #expect(offer.source == "Firmware built into this app: deck panel 1.0.0")
    #expect(offer.reason == "The newest release is no newer than this app's firmware.")
}

@Test func aSoundNewerReleaseSignedWithATrustedKeyIsOffered() async throws {
    let key = TestKey(id: "primary")
    let github = FakeGitHub()
    publish(release(panelVersion: "1.1.0", sha: "bbbbbbb", signedBy: key, name: "deck-panel-1.1.0-bbbbbbb.bin"), on: github)
    let offer = await FirmwareOffer.fetch(http: github, over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"),
                                          cache: temporaryFolder(), trusting: [key.trusted])
    #expect(offer.source == "Firmware from the newest release: deck panel 1.1.0")
    #expect(offer.reason == nil)
}
