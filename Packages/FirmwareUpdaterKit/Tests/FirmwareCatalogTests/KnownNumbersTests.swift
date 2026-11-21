import Foundation
import Testing
import FirmwareCatalog

/// The unit check's numbers (#692): which firmware a chip runs, known by numbers only, never the firmware itself.
@Suite("Catalog: the numbers LC6000 firmware is known by")
struct KnownNumbersTests {
    @Test("The built-in catalog knows stock wd 00.50 by the trailer CRC the kit's patch names, and no tp hash yet")
    func builtIn() throws {
        let kit = try String(contentsOf: kitPatches.appending(path: "wd-00.50-show-slot-16.patch"), encoding: .utf8)
        let named = try #require(kit.firstMatch(of: /trailer CRC 0x([0-9A-F]{8})/)).1
        let known = try Catalog.builtIn().knownNumbers
        #expect(known.display == [UInt32(named, radix: 16)!: "00.50"])
        #expect(known.topPanel == [:])
    }

    @Test("A known number that isn't one: the catalog doesn't load",
          arguments: [#"{"wd_crc": "3A7CE2CA", "tp_sha256": null}"#,
                      #"{"wd_crc": "0x3A7CE2C", "tp_sha256": null}"#,
                      #"{"wd_crc": null, "tp_sha256": "1690"}"#])
    func badNumber(known: String) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "known-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"panel": [], "lc6000": [{"wd": "00.50", "tp": "00.31", "entries": [], "known": \#(known)}]}"#
            .write(to: folder.appending(path: "catalog.json"), atomically: true, encoding: .utf8)
        #expect(throws: CatalogError.self) { try Catalog(directory: folder) }
    }
}
