import CryptoKit
import FirmwareCatalog
import Foundation
import LC6000Update
import Testing
import UnitCheck

/// What a backup's chip runs, against the catalog's patch (#693): stock (patch it), already patched (up to date: the
/// owner's wd chip has run the slot-16 patch since 11-19), or neither (no update offered).
@Suite("LC6000 update: stock, already patched, or unknown")
struct PatchStateTests {
    typealias V = PatchVectorTests

    static func vector(_ name: String) throws -> V.Vector {
        try #require(try V.vectors().first { $0.name.hasPrefix(name) })
    }

    static func sha(_ bytes: [UInt8]) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    @Test("wd: stock 00.50 by its CRC; with the patch's new bytes and a good CRC, already patched; else unknown")
    func display() throws {
        let v = try Self.vector("wd 00.50 slot-16")
        let stock = V.element(v), edits = try V.edits(v)
        let known = KnownNumbers(display: [try #require(DisplayTrailer.crc(of: stock)): "00.50"], topPanel: [:])
        #expect(PatchedImage.state(of: stock, chip: .wd, edits: edits, known: known) == .stock("00.50"))
        let patched = try PatchedImage.apply(edits, chip: .wd, to: stock)
        #expect(PatchedImage.state(of: patched, chip: .wd, edits: edits, known: known) == .alreadyPatched("00.50"))
        var stale = patched
        stale[0x10] ^= 0xFF  // the CRC no longer matches
        #expect(PatchedImage.state(of: stale, chip: .wd, edits: edits, known: known) == .unknown)
        var other = stock
        other[0x10] ^= 0xFF  // not stock, and not the patch's new bytes either
        #expect(PatchedImage.state(of: other, chip: .wd, edits: edits, known: known) == .unknown)
    }

    @Test("tp, as the unit check reads it (the image, then 0xFF to the end of the area): stock by its hash, or patched")
    func topPanel() throws {
        let v = try Self.vector("tp 00.31")
        let stock = V.element(v) + [UInt8](repeating: 0xFF, count: 0x2000), edits = try V.edits(v)
        let known = KnownNumbers(display: [:], topPanel: [Self.sha(stock): "00.31"])
        #expect(PatchedImage.state(of: stock, chip: .tp, edits: edits, known: known) == .stock("00.31"))
        let patched = try PatchedImage.apply(edits, chip: .tp, to: stock)
        #expect(patched.count == stock.count)
        #expect(PatchedImage.state(of: patched, chip: .tp, edits: edits, known: known) == .alreadyPatched("00.31"))
        #expect(PatchedImage.state(of: stock, chip: .tp, edits: edits, known: .none) == .unknown)
    }
}
