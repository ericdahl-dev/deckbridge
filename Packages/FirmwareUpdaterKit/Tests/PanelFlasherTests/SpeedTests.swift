import Testing
@testable import PanelFlasher

/// The ROM starts at 115200; the flasher moves both ends to 921600, the panel's upload speed (platformio.ini), as
/// esptool does: CHANGE_BAUDRATE with the new speed and 0, answered at the old speed, then the Mac's line follows.
@Test func theLineMovesTo921600AndTheChipStillAnswersAfter() async throws {
    let rom = FakeROM()
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    try await bootloader.speedUp()
    #expect(await rom.received.last.map { [UInt8]($0.data) } == [0x00, 0x10, 0x0E, 0x00, 0, 0, 0, 0])
    #expect(await (rom.lineSpeed, rom.romSpeed) == (921_600, 921_600))
    try await bootloader.checkChip()
}
