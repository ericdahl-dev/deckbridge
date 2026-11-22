import Testing
@testable import PanelFlasher

@Test func anEsp32S3IsTheDeckPanelsChip() async throws {
    let rom = FakeROM()
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    try await bootloader.checkChip()
    #expect(await rom.ops.last == 0x14)
}

/// A board on another chip isn't a deck panel: refused, saying which chip it is, and the panel left running.
@Test(arguments: [(UInt32?(5), FlashError.wrongBoard("chip id 5")), (nil, FlashError.wrongBoard("an ESP32 without GET_SECURITY_INFO"))])
func anotherChipIsAWrongBoard(id: UInt32?, refusal: FlashError) async throws {
    let rom = FakeROM()
    await rom.setChipID(id)
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    await #expect(throws: refusal) { try await bootloader.checkChip() }
    #expect(await rom.mode == .app)
}

/// A command's time is wall-clock time, not a count of reads: on a noisy line every read returns at once with a stray
/// frame, and an answer 0.3 s away must still be waited for (embedded review, #687).
@Test func anAnswerThatTakesAWhileIsWaitedForOnANoisyLine() async throws {
    let rom = FakeROM()
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    await rom.setChatter(true)
    await rom.setSecurityInfoDelay(.milliseconds(300))
    try await bootloader.checkChip()
}

@Test func anEsp32S2IsAWrongBoard() async throws {
    let rom = FakeROM()
    await rom.setS2()
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    await #expect(throws: FlashError.wrongBoard("an ESP32-S2")) { try await bootloader.checkChip() }
}

/// An S3 with secure boot, secure download or flash encryption on (GET_SECURITY_INFO's flags bits 0 and 2, and an odd
/// number of flash_crypt_cnt bits): plain bytes written to it wouldn't boot. Refused before anything is written.
@Test(arguments: [(UInt32(1), UInt8(0)), (UInt32(4), UInt8(0)), (UInt32(0), UInt8(1)), (UInt32(0), UInt8(0b111))])
func aLockedDownS3IsRefused(flags: UInt32, cryptCount: UInt8) async throws {
    let rom = FakeROM()
    await rom.setSecurity(flags: flags, cryptCount: cryptCount)
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    await #expect(throws: FlashError.wrongBoard("an ESP32-S3 with secure boot or flash encryption on")) {
        try await bootloader.checkChip()
    }
}

@Test func anS3WithAnEvenFlashCryptCountIsNotEncrypted() async throws {
    let rom = FakeROM()
    await rom.setSecurity(flags: 0, cryptCount: 0b11)
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    try await bootloader.checkChip()
}
