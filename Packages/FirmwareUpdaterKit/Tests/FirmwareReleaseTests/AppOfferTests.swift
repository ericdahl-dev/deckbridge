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
    publish(assets: release.files.merging(["manifest.json": release.manifest, "manifest.sig": release.signature]) { $1 },
            on: github)
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

/// The newest release is an app release with no firmware manifest (every release so far): nothing went wrong talking
/// to GitHub, so the screen mustn't say it couldn't be reached.
@Test(arguments: [["DeckBridge-1.1.0.zip"], ["manifest.json", "DeckBridge-1.1.0.zip"], ["manifest.sig"]])
func aLatestReleaseWithoutASignedManifestSaysNoneIsPublishedYet(assets: [String]) async throws {
    let github = FakeGitHub()
    publish(assets: Dictionary(uniqueKeysWithValues: assets.map { ($0, Data("bytes".utf8)) }), on: github)
    let outcome = await ReleaseFetcher(feed: GitHubReleaseFeed(http: github), trusting: ReleaseKeys.trusted, cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .noFirmwareRelease)
    let offer = FirmwareOffer(outcome)
    #expect(offer.source == "Firmware built into this app: deck panel 1.0.0")
    #expect(offer.reason == "No signed firmware release is published yet, so the firmware built into this app is offered.")
}

/// GitHub's latest link answers 404 when nothing is published, or the newest release has no manifest: that's not "couldn't be reached".
@Test func noPublishedReleaseAtAllSaysNoneIsPublishedYet() async throws {
    let github = FakeGitHub()
    github.answers[latestURL] = HTTPResponse(status: 404, body: Data("Not Found".utf8))
    let outcome = await ReleaseFetcher(feed: GitHubReleaseFeed(http: github), trusting: ReleaseKeys.trusted, cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .noFirmwareRelease)
    #expect(github.asked.map(\.url) == [latestURL])
}
