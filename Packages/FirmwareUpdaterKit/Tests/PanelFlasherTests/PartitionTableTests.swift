import CryptoKit
import Foundation
import Testing
@testable import PanelFlasher

/// The deck panel's partition table as Espressif's gen_esp32part.py writes it from tools/deck-panel/partitions.csv:
/// a 32-byte entry per row (AA 50, type, subtype, offset, size, a 16-byte label, flags), an MD5 entry (EB EB, FF × 14,
/// the MD5 of the rows), then FF up to 3,072 bytes. gen_esp32part.py's own output has MD5 118cbdbf…af2fce8.
func deckPanelPartitionTable() -> [UInt8] {
    let rows: [(type: UInt8, subtype: UInt8, offset: UInt32, size: UInt32, label: String)] = [
        (0x01, 0x02, 0x9000, 0x5000, "nvs"), (0x01, 0x00, 0xE000, 0x2000, "otadata"),
        (0x00, 0x10, 0x10000, 0x64_0000, "app0"), (0x00, 0x11, 0x65_0000, 0x64_0000, "app1"),
        (0x01, 0x82, 0xC9_0000, 0x36_0000, "spiffs"), (0x01, 0x03, 0xFF_0000, 0x1_0000, "coredump"),
    ]
    func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
    var table: [UInt8] = []
    for row in rows {
        let label = Array(row.label.utf8) + [UInt8](repeating: 0, count: 16 - row.label.utf8.count)
        table += [0xAA, 0x50, row.type, row.subtype] + le(row.offset) + le(row.size) + label + le(0)
    }
    let md5 = Array(Insecure.MD5.hash(data: Data(table)))
    table += [0xEB, 0xEB] + [UInt8](repeating: 0xFF, count: 14) + md5
    return table + [UInt8](repeating: 0xFF, count: 3072 - table.count)
}

@Test func theTestsTableIsGenEsp32partsByteForByte() {
    let md5 = Insecure.MD5.hash(data: Data(deckPanelPartitionTable())).map { String(format: "%02x", $0) }.joined()
    #expect(md5 == "118cbdbfce82eb12bbdeb7c59af2fce8")
}

@Test func aBoardWithTheDeckPanelsPartitionTableIsTakenForUpdate() async throws {
    let rom = FakeROM()
    await rom.setFlash(deckPanelPartitionTable(), at: 0x8000)
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    try await bootloader.checkChip()
    try await bootloader.checkPartitionTable()
}

/// An ESP32-S3 with another layout, or a blank one: refused before anything is written, in plain words, and left
/// running. (Turning such a board into a deck panel comes with the bootloader and table in the catalog.)
@Test(arguments: [[UInt8](), [0xAA, 0x50, 0x01, 0x02]])
func aBoardWithoutItIsRefusedBeforeAnyWrite(table: [UInt8]) async throws {
    let rom = FakeROM()
    await rom.setFlash(table, at: 0x8000)
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    try await bootloader.checkChip()
    await #expect(throws: FlashError.notADeckPanel) { try await bootloader.checkPartitionTable() }
    #expect(await rom.begun.isEmpty)
    #expect(await rom.mode == .app)
}
