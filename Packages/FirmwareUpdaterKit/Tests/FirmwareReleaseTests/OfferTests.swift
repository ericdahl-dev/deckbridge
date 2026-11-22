import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel
import FirmwareRelease

// What the updater's screen says about the firmware it offers (#704): built into the app or from the newest release,
// and, when the release wasn't used, why, in plain words.

@Test func aReleaseTheFetcherTookIsOfferedAsTheReleasesFirmware() async throws {
    let key = TestKey(id: "primary")
    let outcome = await ReleaseFetcher(feed: release(panelVersion: "1.1.0", sha: "bbbbbbb", signedBy: key),
                                       trusting: [key.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    let offer = FirmwareOffer(outcome)
    #expect(offer.source == "Firmware from the newest release: deck panel 1.1.0")
    #expect(offer.reason == nil)
}

@Test(arguments: [
    (Refusal.unreachable, "GitHub couldn't be reached, so the firmware built into this app is offered."),
    (.unknownKey("primary"), "The newest release is signed with a key this app doesn't trust yet, so the firmware built into this app is offered."),
    (.badSignature, "The newest release's signature doesn't check out, so the firmware built into this app is offered."),
    (.unreadableManifest, "The newest release's manifest can't be read, so the firmware built into this app is offered."),
    (.fileMismatch("deck-panel-1.1.0.bin"), "A file in the newest release (deck-panel-1.1.0.bin) isn't what its manifest says, so the firmware built into this app is offered."),
    (.unsafeFileName("../x"), "The newest release names a file outside its folder, so the firmware built into this app is offered."),
    (.notNewer, "The newest release is no newer than this app's firmware."),
    (.notACatalog(.unnamedFile("x")), "The newest release's catalog isn't one this app accepts, so the firmware built into this app is offered."),
    (.unreadableCatalog, "The newest release's catalog isn't one this app accepts, so the firmware built into this app is offered."),
    (.couldNotStore, "The newest release couldn't be saved on this Mac, so the firmware built into this app is offered."),
    (.dropsBuiltIn, "The newest release leaves out firmware this app carries, so the firmware built into this app is offered."),
    (.unknownFormat(2), "The newest release needs a newer version of this app, so the firmware built into this app is offered."),
])
func aRefusedReleaseOffersTheBuiltInFirmwareAndSaysWhy(refusal: Refusal, reason: String) throws {
    let offer = FirmwareOffer(FetchOutcome(catalog: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"), refusal: refusal))
    #expect(offer.source == "Firmware built into this app: deck panel 1.0.0")
    #expect(offer.reason == reason)
}

@Test func anAppCarryingNoPanelImageSaysSo() throws {
    let folder = temporaryFolder()
    try Data(#"{"panel": [], "lc6000": []}"#.utf8).write(to: folder.appending(path: "catalog.json"))
    let offer = FirmwareOffer(FetchOutcome(catalog: try Catalog(directory: folder), refusal: .unreachable))
    #expect(offer.source == "No deck panel firmware built into this app")
}
