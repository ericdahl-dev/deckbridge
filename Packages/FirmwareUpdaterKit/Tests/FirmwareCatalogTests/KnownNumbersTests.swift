import Foundation
import Testing
import FirmwareCatalog

/// The unit check's numbers (#692): which firmware a chip runs, known by numbers only, never the firmware itself.
@Suite("Catalog: the numbers LC6000 firmware is known by")
struct KnownNumbersTests {
    @Test("The built-in catalog knows stock wd 00.50 by the trailer CRC the kit's patch names, and stock tp 00.31 by its hash")
    func builtIn() throws {
        let kit = try String(contentsOf: kitPatches.appending(path: "wd-00.50-show-slot-16.patch"), encoding: .utf8)
        let named = try #require(kit.firstMatch(of: /trailer CRC 0x([0-9A-F]{8})/)).1
        let known = try Catalog.builtIn().knownNumbers
        #expect(known.display == [UInt32(named, radix: 16)!: "00.50"])
        // The SHA-256 of the 229376-byte app area as the app reads it, from the owner's unit (#709, cos, 2026-11-22):
        // the first 96K stock tp 00.31, the rest 0xFF. It holds for that read range only.
        #expect(known.topPanel == ["1f97959902b2febae979e47ab9a9c09b5b362d17e5736ac110df5f1a761a76cc": "00.31"])
    }

    @Test("A known number that isn't one: the catalog doesn't load",
          arguments: [#"{"wd_crc": "3A7CE2CA", "tp_sha256": null}"#,
                      #"{"wd_crc": "0x3A7CE2C", "tp_sha256": null}"#,
                      #"{"wd_crc": null, "tp_sha256": "1690"}"#,
                      #"{"wd_crc": null, "tp_sha256": null, "wd_ours": [{"crc": "33A7BEBB", "label": "x"}]}"#])
    func badNumber(known: String) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "known-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"panel": [], "lc6000": [{"wd": "00.50", "tp": "00.31", "entries": [], "known": \#(known)}]}"#
            .write(to: folder.appending(path: "catalog.json"), atomically: true, encoding: .utf8)
        #expect(throws: CatalogError.self) { try Catalog(directory: folder) }
    }

    /// The owner's wd chip, backed up 2026-11-22 (#692, cos): byte for byte the image flashed 11-19, stock 00.50 with the
    /// slot-16 patch and the drawn display's block A (sha1 07da7ec9…). Its trailer CRC is ours, so it's up to date.
    @Test("The built-in catalog knows our drawn-display wd image by its trailer CRC")
    func drawnDisplayImage() throws {
        let known = try Catalog.builtIn().knownNumbers
        #expect(known.displayOurs == [0x33A7_BEBB: "00.50 with slot 16 and DeckBridge's drawn display (block A 07da7ec9)"])
        #expect(known.display[0x33A7_BEBB] == nil)
    }
}
