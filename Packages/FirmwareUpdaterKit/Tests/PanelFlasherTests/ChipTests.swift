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
