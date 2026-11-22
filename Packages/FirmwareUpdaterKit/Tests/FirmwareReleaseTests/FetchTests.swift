import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel
import FirmwareRelease

@Test func aSignedReleaseNewerThanTheBuiltInIsOfferedFromTheFeed() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary)
    let fetcher = ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
    let outcome = await fetcher.fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    let newest = try #require(outcome.catalog.newestPanel())
    #expect(newest.version == FirmwareVersion("1.1.0"))
    #expect(try Data(contentsOf: newest.image) == panelImage("1.1.0"))
}

@Test func aReleaseWhoseSignatureDoesNotMatchIsRefusedAndTheBuiltInStays() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary)
    feed.signature = TestKey(id: "primary").sign(feed.manifest)  // a different key claiming to be the primary
    let builtIn = try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa")
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder()).fetch(over: builtIn)
    #expect(outcome.refusal == .badSignature)
    #expect(outcome.catalog.newestPanel()?.version == FirmwareVersion("1.0.0"))
}

@Test func aManifestChangedAfterSigningIsRefused() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary)
    feed.manifest = Data(String(decoding: feed.manifest, as: UTF8.self).replacingOccurrences(of: "1.1.0", with: "9.9.9").utf8)
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .badSignature)
}

@Test func aReleaseSignedByAKeyTheAppDoesNotTrustIsRefusedByName() async throws {
    let stranger = TestKey(id: "someone-else")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: stranger)
    let outcome = await ReleaseFetcher(feed: feed, trusting: [TestKey(id: "primary").trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .unknownKey("someone-else"))
}

/// ADR 0012: the app trusts the offline backup key from day one, so a release signed with it after the primary is lost works.
@Test func aReleaseSignedByTheBackupKeyIsAccepted() async throws {
    let primary = TestKey(id: "primary"), backup = TestKey(id: "backup")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: backup)
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted, backup.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == nil)
    #expect(outcome.catalog.newestPanel()?.version == FirmwareVersion("1.1.0"))
}

@Test func aFileWhoseBytesDifferFromTheManifestIsRefused() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary)
    let name = "panel/deck-panel-1.1.0-ddddddd.bin"
    feed.files[name] = panelImage("1.1.1")  // same length, different bytes
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .fileMismatch(name))
    #expect(outcome.catalog.newestPanel()?.version == FirmwareVersion("1.0.0"))
}

@Test func aFileCutShortIsRefused() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary)
    let name = "panel/deck-panel-1.1.0-ddddddd.bin"
    feed.files[name] = feed.files[name]!.prefix(5)
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .fileMismatch(name))
}

@Test(arguments: [0.5, 0.0])
func aManifestCutShortIsRefused(kept: Double) async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary)
    feed.manifest = feed.manifest.prefix(Int(Double(feed.manifest.count) * kept))
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .unreadableManifest)
    #expect(outcome.catalog.newestPanel()?.version == FirmwareVersion("1.0.0"))
}

/// Even a validly signed manifest (a stolen key, say) can't make the app write outside the release's own folder.
@Test(arguments: ["../escaped.bin", "panel/../../escaped.bin", "/tmp/escaped.bin"])
func aFileNamedOutsideTheReleaseFolderIsRefusedAndNotWritten(name: String) async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary, name: name)
    let cache = temporaryFolder()
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: cache)
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .unsafeFileName(name))
    #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "escaped.bin").path(percentEncoded: false)))
}

@Test(arguments: ["1.0.0", "0.9.0"])
func aReleaseNotNewerThanTheBuiltInIsNotUsed(version: String) async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: version, sha: "ddddddd", signedBy: primary, lowestAllowed: "0.1.0")
    let builtIn = try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa")
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder()).fetch(over: builtIn)
    #expect(outcome.refusal == .notNewer)
    #expect(outcome.catalog.newestPanel()?.sha == "aaaaaaa")
}

/// Works offline (#684, story 21): with no network the built-in firmware stays, and the app can say why.
@Test func withNoNetworkTheBuiltInStaysAndTheReasonIsUnreachable() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary)
    feed.unreachable = true
    let builtIn = try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa")
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder()).fetch(over: builtIn)
    #expect(outcome.refusal == .unreachable)
    #expect(outcome.catalog.newestPanel()?.sha == "aaaaaaa")
}

/// A fetched release goes through the same guards as the built-in catalog (#686): validly signed or not, an LC6000
/// entry bigger than a patch description is refused, so no image of Denon's can arrive this way.
@Test func aFetchedLC6000EntryThatIsNotAPatchDescriptionIsRefused() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary, wdPatch: Data(repeating: 0xFF, count: 64 * 1024))
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .notACatalog(.notAPatchDescription("lc6000/wd-00.50.patch")))
    #expect(outcome.catalog.newestPanel()?.sha == "aaaaaaa")
}

@Test func aFetchedReleaseWithAPatchDescriptionCarriesItsPatchSet() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary, wdPatch: Data("0x0800BDA4 0f28 1028\n".utf8))
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == nil)
    #expect(outcome.catalog.patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31"))?.entries.count == 1)
}

/// ADR 0012: a signed manifest sets the lowest panel version a device may go back to; the Wi-Fi update (#690) uses it.
@Test func aUsedReleaseCarriesItsLowestAllowedPanelVersion() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary, lowestAllowed: "1.0.5")
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.lowestAllowedPanel == FirmwareVersion("1.0.5"))
}

/// Every way a release can fail says why: a signed manifest whose catalog the app can't read isn't a silent fallback.
@Test func aSignedReleaseWhoseCatalogCannotBeReadIsRefusedWithAReason() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary,
                       catalog: ["panel": [["version": "1.1.0", "sha": "ddddddd", "image": "panel/deck-panel-1.1.0-ddddddd.bin"]]])
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .unreadableCatalog)
    #expect(outcome.catalog.newestPanel()?.sha == "aaaaaaa")
}

/// The network dropping after a good manifest, mid-files, is "unreachable" too.
@Test func theNetworkDroppingDuringTheFilesIsUnreachable() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary)
    feed.files = [:]
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .unreachable)
}

/// A used release replaces the built-in catalog, so it must carry everything the built-in one does: an LC6000 patch
/// set, and the panel builds shipped before (which tell an older panel from an unknown one).
@Test func aReleaseThatDropsABuiltInPatchSetIsRefused() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary)
    let builtIn = try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa", withPatchSet: true)
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder()).fetch(over: builtIn)
    #expect(outcome.refusal == .dropsBuiltIn)
    #expect(outcome.catalog.patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31")) != nil)
}

@Test func aReleaseThatDropsABuiltInPanelBuildIsRefused() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary, history: [])  // lists only its own build
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .dropsBuiltIn)
}

/// A manifest in a later format than this app reads is refused, not half-read: the app must be updated first.
@Test func aManifestInAFormatThisAppDoesNotKnowIsRefused() async throws {
    let primary = TestKey(id: "primary")
    let feed = release(panelVersion: "1.1.0", sha: "ddddddd", signedBy: primary, format: 2)
    let outcome = await ReleaseFetcher(feed: feed, trusting: [primary.trusted], cache: temporaryFolder())
        .fetch(over: try builtIn(panelVersion: "1.0.0", sha: "aaaaaaa"))
    #expect(outcome.refusal == .unknownFormat(2))
}
