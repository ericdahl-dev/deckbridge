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
    let a = Data(repeating: 0xA5, count: 64), b = Data(repeating: 0x5B, count: 64)
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
    let a = Data(repeating: 0xA5, count: 64), b = Data(repeating: 0x5B, count: 64)
    let otherA = Data(repeating: 0xA6, count: 64), otherB = Data(repeating: 0x5C, count: 64)
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
    let folder = try catalog(a: Data(repeating: 0xA5, count: 64), b: Data(repeating: 0x5B, count: 64), parts: [kept])
    #expect(throws: CatalogError.missingBlock(kept == "a" ? "b" : "a")) { try Catalog(directory: folder) }
}
