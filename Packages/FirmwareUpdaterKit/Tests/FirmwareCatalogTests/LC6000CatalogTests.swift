import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel

@Test func aUnitOnTheTestedVersionsGetsThePatchSetForBothChips() throws {
    let catalog = try Catalog(directory: fixture("lc6000"))
    let set = try #require(catalog.patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31")))
    #expect(set.entries.map(\.chip) == [.wd, .tp])
    #expect(set.entries.map(\.file.lastPathComponent) == ["wd-one.patch", "tp-one.patch"])
}

@Test func aUnitWithEitherChipOnAnotherVersionGetsNoPatchSet() throws {
    let catalog = try Catalog(directory: fixture("lc6000"))
    #expect(catalog.patchSet(for: LC6000Firmware(wd: "00.51", tp: "00.31")) == nil)
    #expect(catalog.patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.30")) == nil)
    #expect(catalog.patchSet(for: LC6000Firmware(wd: "", tp: "")) == nil)
}

/// The app never carries Denon's bytes (#684): an LC6000 patch entry must be a patch description, a few
/// "ADDRESS OLD NEW" lines and comments. Anything bigger or of another shape stops the catalog loading.
@Test(arguments: ["too-long-edit", "not-a-description", "binary"])
func aCatalogWhoseLC6000PatchIsNotAPatchDescriptionDoesNotLoad(name: String) throws {
    #expect(throws: CatalogError.notAPatchDescription("wd-bad.patch")) { try Catalog(directory: fixture(name)) }
}

@Test func aPatchDescriptionsEditsAreRead() throws {
    let catalog = try Catalog(directory: fixture("lc6000"))
    let set = try #require(catalog.patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31")))
    #expect(set.entries[1].edits == [PatchEdit(address: 0x0801_5CDB, old: [0x0A, 0x14, 0xFF, 0x64], new: [0x0A, 0x14, 0x00, 0x64])])
}

/// A file the catalog doesn't name (say, an image dropped next to the patches) stops it loading.
@Test func aCatalogFolderHoldingAFileItDoesNotNameDoesNotLoad() throws {
    #expect(throws: CatalogError.unnamedFile("firmware/not-named-here.bin")) {
        try Catalog(directory: fixture("stray-file"))
    }
}

/// A catalog names only files inside its own folder: it never reads, or offers, a file from elsewhere on the Mac.
@Test func aCatalogNamingAFileOutsideItsFolderDoesNotLoad() throws {
    #expect(throws: CatalogError.outsideFolder("../lc6000/wd-one.patch")) { try Catalog(directory: fixture("escaping-name")) }
}
