import Testing
@testable import PanelFlasher

final class Progress: @unchecked Sendable { var seen: [Double] = [] }

private func connected(_ rom: FakeROM) async throws -> Bootloader {
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    try await bootloader.checkChip()
    return bootloader
}

/// An image 2.5 blocks long, so the last block is padded with FF, as esptool pads it.
private let image: [UInt8] = (0..<2600).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) }

@Test func anImageIsWrittenAtItsAddressBlockByBlockWithProgress() async throws {
    let rom = FakeROM()
    let bootloader = try await connected(rom)
    let progress = Progress()
    try await bootloader.write(image, at: 0x10000) { progress.seen.append($0) }
    #expect(await rom.flashBytes(at: 0x10000, count: image.count) == image)
    #expect(await rom.flashBytes(at: 0x10000 + UInt32(image.count), count: 3 * 1024 - image.count).allSatisfy { $0 == 0xFF })
    #expect(progress.seen == [1.0 / 3, 2.0 / 3, 1.0])
}

/// A block the chip refuses is tried three times (esptool's WRITE_BLOCK_ATTEMPTS), then the write fails, naming where,
/// and the panel is left running.
@Test func aBlockTheChipKeepsRefusingIsAFailedWrite() async throws {
    let rom = FakeROM()
    await rom.setFailingBlock(1)
    let bootloader = try await connected(rom)
    await #expect(throws: FlashError.writeFailed(address: 0x10400)) {
        try await bootloader.write(image, at: 0x10000) { _ in }
    }
    #expect(await rom.received.filter { $0.op == 0x03 && $0.data.count > 8 && $0.data[4] == 1 }.count == 3)
    #expect(await rom.mode == .app)
}
