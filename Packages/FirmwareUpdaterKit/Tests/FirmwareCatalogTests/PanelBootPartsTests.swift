import CryptoKit
import Foundation
import Testing
import FirmwareCatalog
import FirmwareModel

// A panel entry can carry the two other files `pio upload` writes (#687), so a blank or foreign ESP32-S3 board can be
// made a deck panel: the bootloader (at 0x0) and the partition table (at 0x8000), both from the panel's own build.
// The bytes here are made up in the tests.

/// A partition table's shape: 32-byte rows starting AA 50, then the MD5 row (EB EB, FF × 14, the rows' MD5), then FF
/// up to 3,072 bytes, as gen_esp32part.py writes it.
private func table(rows: Int = 2, breakMD5: Bool = false) -> Data {
    var bytes: [UInt8] = []
    for i in 0..<rows { bytes += [0xAA, 0x50, 0x01, UInt8(i)] + [UInt8](repeating: 0, count: 28) }
    var md5 = Array(Insecure.MD5.hash(data: Data(bytes)))
    if breakMD5 { md5[0] ^= 1 }
    bytes += [0xEB, 0xEB] + [UInt8](repeating: 0xFF, count: 14) + md5
    return Data(bytes + [UInt8](repeating: 0xFF, count: 3072 - bytes.count))
}

private let image = Data([0xE9] + [UInt8](repeating: 0x11, count: 64))
private let bootloader = Data([0xE9] + [UInt8](repeating: 0x22, count: 64))

private func catalog(bootloader: Data?, partitions: Data?) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "boot-parts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appending(path: "panel"), withIntermediateDirectories: true)
    var entry = "\"version\": \"1.1.0\", \"sha\": \"1d0683f\", \"image\": \"panel/app.bin\""
    try image.write(to: folder.appending(path: "panel/app.bin"))
    if let bootloader {
        entry += ", \"bootloader\": \"panel/bootloader.bin\""
        try bootloader.write(to: folder.appending(path: "panel/bootloader.bin"))
    }
    if let partitions {
        entry += ", \"partitions\": \"panel/partitions.bin\""
        try partitions.write(to: folder.appending(path: "panel/partitions.bin"))
    }
    try Data("{\"panel\": [{\(entry)}], \"lc6000\": []}".utf8).write(to: folder.appending(path: "catalog.json"))
    return folder
}

@Test func aPanelEntryCarriesItsBootloaderAndPartitionTable() throws {
    let newest = try #require(try Catalog(directory: catalog(bootloader: bootloader, partitions: table())).newestPanel())
    #expect(try newest.bootParts.map { try Data(contentsOf: $0.bootloader) } == bootloader)
    #expect(try newest.bootParts.map { try Data(contentsOf: $0.partitions) } == table())
}

@Test func anEntryWithNeitherStillLoadsForUpdates() throws {
    let newest = try #require(try Catalog(directory: catalog(bootloader: nil, partitions: nil)).newestPanel())
    #expect(newest.bootParts == nil)
}

@Test(arguments: [(true, false), (false, true)])
func oneWithoutTheOtherDoesNotLoad(hasBootloader: Bool, hasPartitions: Bool) throws {
    #expect(throws: CatalogError.missingBootPart("1.1.0")) {
        try Catalog(directory: catalog(bootloader: hasBootloader ? bootloader : nil, partitions: hasPartitions ? table() : nil))
    }
}

@Test(arguments: [
    Data([0x00] + [UInt8](repeating: 0x22, count: 64)),  // not an ESP32 image
    Data([0xE9] + [UInt8](repeating: 0x22, count: 0x8000)),  // past 0x8000, over the partition table
])
func aBootloaderNotShapedLikeOneDoesNotLoad(bytes: Data) throws {
    #expect(throws: CatalogError.notABootloader("panel/bootloader.bin")) {
        try Catalog(directory: catalog(bootloader: bytes, partitions: table()))
    }
}

@Test(arguments: [table(breakMD5: true), table().prefix(3071), Data(repeating: 0xFF, count: 3072)])
func aPartitionTableNotShapedLikeOneDoesNotLoad(bytes: Data) throws {
    #expect(throws: CatalogError.notAPartitionTable("panel/partitions.bin")) {
        try Catalog(directory: catalog(bootloader: bootloader, partitions: Data(bytes)))
    }
}
