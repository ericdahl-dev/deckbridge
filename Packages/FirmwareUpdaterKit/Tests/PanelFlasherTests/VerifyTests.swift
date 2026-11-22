import Testing
@testable import PanelFlasher

private let image: [UInt8] = (0..<2600).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) }

private func written(_ rom: FakeROM) async throws -> Bootloader {
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    try await bootloader.checkChip()
    try await bootloader.write(image, at: 0x10000) { _ in }
    return bootloader
}

@Test func aWrittenImageVerifiesByTheChipsOwnMD5() async throws {
    let rom = FakeROM()
    let bootloader = try await written(rom)
    try await bootloader.verify(image, at: 0x10000)
    #expect(await rom.ops.last == 0x13)
}

/// The flash doesn't hold what was sent (a bad cell, say): the verify fails, and the panel is left running. Its old
/// app slot isn't trusted: the owner is told to try again.
@Test func flashThatDiffersFromTheImageIsAFailedVerify() async throws {
    let rom = FakeROM()
    let bootloader = try await written(rom)
    await rom.setFlash([image[100] ^ 0x01], at: 0x10000 + 100)
    await #expect(throws: FlashError.verifyFailed(address: 0x10000)) { try await bootloader.verify(image, at: 0x10000) }
    #expect(await rom.mode == .app)
}
