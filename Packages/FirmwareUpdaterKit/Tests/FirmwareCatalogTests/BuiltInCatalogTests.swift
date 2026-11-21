import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel

/// The flash kit's patch descriptions, the reference the app's copies must match byte for byte.
let kitPatches = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../../tools/lc6000-firmware/patches").standardized

@Test func theBuiltInCatalogFitsTheOwnersUnitWithSlot16AndNoDeckSelect() throws {
    let set = try #require(try Catalog.builtIn().patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31")))
    #expect(set.entries.map(\.file.lastPathComponent)
        == ["wd-00.50-show-slot-16.patch", "tp-00.31-no-deck-select-on-hello.patch"])
    #expect(set.entries.map(\.chip) == [.wd, .tp])
}

@Test func everyBuiltInPatchIsTheKitsFileByteForByte() throws {
    let sets = [try #require(try Catalog.builtIn().patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31")))]
    for entry in sets.flatMap(\.entries) {
        let kit = try Data(contentsOf: kitPatches.appending(path: entry.file.lastPathComponent))
        #expect(try Data(contentsOf: entry.file) == kit, "\(entry.file.lastPathComponent) differs from the kit's")
    }
}

/// Works offline (#684, story 21): everything the built-in catalog hands out is a file already on this Mac.
@Test func everythingTheBuiltInCatalogHandsOutIsALocalFile() throws {
    let set = try #require(try Catalog.builtIn().patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31")))
    for url in set.entries.map(\.file) {
        #expect(url.isFileURL)
        #expect(FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)), "\(url) is not on disk")
    }
}

/// The catalog reads the kit's patch format: every patch description in the kit loads as one, so the two readers
/// can't drift apart unnoticed. Built in a temporary folder, as the catalog would hold them.
@Test func everyPatchDescriptionInTheKitLoadsAsOne() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let names = try FileManager.default.contentsOfDirectory(atPath: kitPatches.path(percentEncoded: false))
        .filter { $0.hasSuffix(".patch") }.sorted()
    #expect(names.count == 4)
    for name in names { try FileManager.default.copyItem(at: kitPatches.appending(path: name), to: folder.appending(path: name)) }
    let entries = names.map { #"{ "kind": "patch", "chip": "\#($0.prefix(2))", "file": "\#($0)" }"# }
    let json = #"{ "panel": [], "lc6000": [{ "wd": "x", "tp": "y", "entries": [\#(entries.joined(separator: ","))] }] }"#
    try Data(json.utf8).write(to: folder.appending(path: "catalog.json"))
    let set = try #require(try Catalog(directory: folder).patchSet(for: LC6000Firmware(wd: "x", tp: "y")))
    #expect(set.entries.map(\.edits.count) == [1, 2, 1, 1])
}
