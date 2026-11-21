import CryptoKit
import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel

// The drawn jog display's own code (#696): block A and block B, built from this repo, carried beside the patch
// descriptions. The bytes here are made up in the tests, never kept as fixture files.

private func sha1(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Block A's shape: the 9,184-byte wd padding, ending in its marker "DFW1" (arm/hook.h), filled with `fill`.
private func ownA(fill: UInt8 = 0xA5) -> Data {
    Data(repeating: fill, count: 9180) + Data([0x44, 0x46, 0x57, 0x31])
}

/// Block B's shape: the worked example in arm/test/test_upper_header.py, its header (marker "DFWB", version 4, length
/// 37, CRC 0x6ACCA34B worked out apart there, layout, draw, band) and the body "123456789".
private func ownB() -> Data {
    let words: [UInt32] = [0x4257_4644, 4, 37, 0x6ACC_A34B, 0x1A2B_3C4D, 0x0808_001D, 0x0808_001F]
    return Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } }) + Data("123456789".utf8)
}

private func word(_ data: Data, at offset: Int, _ value: UInt32) -> Data {
    var out = data
    for i in 0..<4 { out[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    return out
}

/// A catalog folder for wd 00.50 / tp 00.31 holding `a`, `b` and the build record `make arm` writes beside them.
/// `recordA` and `recordB` are the blocks the record names (by default, `a` and `b` themselves); `parts` are the
/// blocks the set lists and the folder holds.
private func catalog(a: Data, b: Data, recordA: Data? = nil, recordB: Data? = nil, parts: [String] = ["a", "b"]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "own-blocks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appending(path: "lc6000"), withIntermediateDirectories: true)
    let named = (a: recordA ?? a, b: recordB ?? b)
    let record = """
        {"record": 1, "commit": "0123456789ab", "built": 1,
         "block_a": {"sha1": "\(sha1(named.a))", "length": \(named.a.count), "draw": "1", "proven": "1"},
         "block_b": {"sha1": "\(sha1(named.b))", "length": \(named.b.count), "layout": 1, "header_version": 4}}
        """
    let files = ["a": ("lc6000/block.bin", a), "b": ("lc6000/upper.bin", b)]
    let entries = parts.map { part in
        "{\"kind\": \"block\", \"chip\": \"wd\", \"part\": \"\(part)\", \"file\": \"\(files[part]!.0)\", \"record\": \"lc6000/build.json\"}"
    }
    let json = "{\"panel\": [], \"lc6000\": [{\"wd\": \"00.50\", \"tp\": \"00.31\", \"entries\": [\(entries.joined(separator: ", "))]}]}"
    try Data(json.utf8).write(to: folder.appending(path: "catalog.json"))
    try Data(record.utf8).write(to: folder.appending(path: "lc6000/build.json"))
    for part in parts { try files[part]!.1.write(to: folder.appending(path: files[part]!.0)) }
    return folder
}

@Test func aSetCarryingBlockAAndBlockBFromOneBuildOffersThemAsThePair() throws {
    let a = ownA(), b = ownB()
    let loaded = try Catalog(directory: catalog(a: a, b: b))
    let set = try #require(loaded.patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31")))
    let blocks = try #require(set.blocks)
    #expect(try Data(contentsOf: blocks.a) == a)
    #expect(try Data(contentsOf: blocks.b) == b)
    #expect(blocks.commit == "0123456789ab")
    #expect(set.entries.map(\.kind) == [.block, .block])
}

/// A and B from different builds stay silent together (#516): a block whose bytes aren't the ones its build record
/// names stops the catalog loading.
@Test func blockAOrBlockBFromAnotherBuildThanTheRecordDoesNotLoad() throws {
    let a = ownA(), b = ownB()
    let otherA = ownA(fill: 0xA6), otherB = ownB() + Data([0])
    #expect(throws: CatalogError.differentBuilds("lc6000/block.bin")) {
        try Catalog(directory: catalog(a: a, b: b, recordA: otherA))
    }
    #expect(throws: CatalogError.differentBuilds("lc6000/upper.bin")) {
        try Catalog(directory: catalog(a: a, b: b, recordB: otherB))
    }
}

/// One block without the other is no drawn display: block A alone, or B alone, stops the catalog loading.
@Test(arguments: ["a", "b"])
func aSetWithOnlyOneOfTheTwoBlocksDoesNotLoad(kept: String) throws {
    let folder = try catalog(a: ownA(), b: ownB(), parts: [kept])
    #expect(throws: CatalogError.missingBlock(kept == "a" ? "b" : "a")) { try Catalog(directory: folder) }
}

/// The app ships only this repo's own code, never Denon's (#684): a block entry must have the shape of block A or
/// block B as `make arm` builds them. A stock image, a dump or a patched image named as a block stops the catalog
/// loading, even with a build record that names its bytes.
@Test(arguments: [
    ("a: one byte short", Data(ownA().dropLast(5)) + Data([0x44, 0x46, 0x57, 0x31])),
    ("a: no DFW1 marker", Data(repeating: 0xA5, count: 9184)),
    ("a: a whole stock-sized image", Data(repeating: 0xFF, count: 0x7_E000)),
])
func aBlockANotShapedLikeOursDoesNotLoad(_ case: String, a: Data) throws {
    #expect(throws: CatalogError.notOurBlock("lc6000/block.bin"), "\(`case`)") {
        try Catalog(directory: catalog(a: a, b: ownB()))
    }
}

@Test(arguments: [
    ("b: no DFWB marker", word(ownB(), at: 0, 0x2000_5000)),
    ("b: another header version", word(ownB(), at: 4, 3)),
    ("b: longer than its header says", ownB() + Data([0])),
    ("b: its CRC broken", word(ownB(), at: 12, 0x6ACC_A34A)),
    ("b: a body byte changed", Data(ownB().dropLast()) + Data("0".utf8)),
    ("b: shorter than its header", Data(ownB().prefix(20))),
])
func aBlockBNotShapedLikeOursDoesNotLoad(_ case: String, b: Data) throws {
    #expect(throws: CatalogError.notOurBlock("lc6000/upper.bin"), "\(`case`)") {
        try Catalog(directory: catalog(a: ownA(), b: b))
    }
}

@Test func theRefusalSaysPlainlyItIsNotOneOfOurBlocks() {
    #expect(CatalogError.notOurBlock("lc6000/upper.bin").localizedDescription
        == "lc6000/upper.bin is not one of DeckBridge's own blocks")
}

/// The repo commits no block (#696): they're built and staged at release, so the catalog built from the repo has none.
/// In a tree where stage_lc6000_blocks.py has run, this fails, as it should: it pins the repo.
@Test func theBuiltInCatalogFromTheRepoCarriesNoBlocks() throws {
    let set = try #require(Catalog.builtIn().patchSet(for: LC6000Firmware(wd: "00.50", tp: "00.31")))
    #expect(set.blocks == nil)
    #expect(!set.entries.contains { $0.kind == .block })
}
