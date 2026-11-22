import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel

func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

@Test func theNewestPanelFirmwareIsTheHighestVersionNotTheLastListed() throws {
    let catalog = try Catalog(directory: fixture("one-panel"))
    let newest = try #require(catalog.newestPanel())
    #expect(newest.version == FirmwareVersion("1.10.0"))
    #expect(newest.sha == "bbbbbbb")
}

@Test func aPanelOnAnOlderShippedBuildIsOfferedTheNewest() throws {
    let catalog = try Catalog(directory: fixture("one-panel"))
    let newest = try #require(catalog.newestPanel())
    #expect(catalog.offer(for: PanelBuild(sha: "ccccccc")) == .update(newest))
}

@Test func aPanelOnTheNewestBuildIsUpToDate() throws {
    let catalog = try Catalog(directory: fixture("one-panel"))
    #expect(catalog.offer(for: PanelBuild(sha: "bbbbbbb")) == .upToDate)
}

@Test func aPanelOnABuildTheCatalogNeverShippedIsUnknownAndStillOffered() throws {
    let catalog = try Catalog(directory: fixture("one-panel"))
    let newest = try #require(catalog.newestPanel())
    #expect(catalog.offer(for: PanelBuild(sha: "1234567")) == .unknownBuild(newest))
}

@Test func theBootLineShaMayBeLongerThanTheCatalogs() throws {
    let catalog = try Catalog(directory: fixture("one-panel"))
    #expect(catalog.offer(for: PanelBuild(sha: "bbbbbbb0123")) == .upToDate)
}

@Test func aPanelThatReportsAnOlderVersionIsOfferedAnUpdateWhateverItsSha() throws {
    let catalog = try Catalog(directory: fixture("one-panel"))
    let newest = try #require(catalog.newestPanel())
    #expect(catalog.offer(for: PanelBuild(sha: "1234567", version: FirmwareVersion("1.9.9"))) == .update(newest))
}

@Test func aPanelThatReportsTheNewestVersionOrLaterIsUpToDate() throws {
    let catalog = try Catalog(directory: fixture("one-panel"))
    #expect(catalog.offer(for: PanelBuild(sha: "1234567", version: FirmwareVersion("1.10.0"))) == .upToDate)
    #expect(catalog.offer(for: PanelBuild(sha: "ccccccc", version: FirmwareVersion("2.0"))) == .upToDate)
}

/// tools/deck-panel/git_sha.py stamps "<sha>-dirty" on a build with uncommitted changes: not the shipped build.
@Test func aDirtyBuildOfAShippedShaIsUnknown() throws {
    let catalog = try Catalog(directory: fixture("one-panel"))
    let newest = try #require(catalog.newestPanel())
    #expect(catalog.offer(for: PanelBuild(sha: "bbbbbbb-dirty")) == .unknownBuild(newest))
}

/// The catalog lists every panel build ever shipped, but the app carries only the images beside it (a build from
/// the repo carries none): the newest offered is the newest carried, and a panel on a later shipped build is current.
@Test func onlyACarriedImageIsOfferedAndLaterShippedBuildsAreUpToDate() throws {
    let catalog = try Catalog(directory: fixture("history"))
    let carried = try #require(catalog.newestPanel())
    #expect(carried.sha == "ccccccc")
    #expect(catalog.offer(for: PanelBuild(sha: "aaaaaaa")) == .update(carried))
    #expect(catalog.offer(for: PanelBuild(sha: "bbbbbbb")) == .upToDate)
}

@Test func theBuiltInCatalogFromTheRepoCarriesNoPanelImage() throws {
    #expect(try Catalog.builtIn().offer(for: PanelBuild(sha: "1234567")) == .nothing)
}
