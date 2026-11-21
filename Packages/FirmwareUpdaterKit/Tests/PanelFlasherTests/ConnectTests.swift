import Testing
@testable import PanelFlasher

final class TaskBox: @unchecked Sendable { var task: Task<Void, Error>? }

@Test func connectingResetsThePanelIntoItsBootloaderAndSyncs() async throws {
    let rom = FakeROM()
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    #expect(await rom.mode == .download)
    #expect(await rom.ops.first == 0x08)
}

/// No ESP32 answers: the flasher gives up with a plain reason, and leaves the panel running its app.
@Test func aPanelThatNeverAnswersIsNoBootloaderAndIsLeftRunning() async throws {
    let rom = FakeROM()
    await rom.setAnswers(false)
    let bootloader = Bootloader(line: rom)
    await #expect(throws: FlashError.noBootloader) { try await bootloader.connect() }
    #expect(await rom.mode == .app)
    #expect(await (rom.dtr, rom.rts) == (false, false))
}

/// The owner cancels while the port is open (#687): the panel is reset into its app with both lines off, never left
/// held in reset or in the bootloader.
@Test func cancellingMidConnectLeavesThePanelRunningItsApp() async throws {
    let rom = FakeROM()
    await rom.setAnswers(false)
    let box = TaskBox()
    await rom.setAfterReset { box.task?.cancel() }
    let bootloader = Bootloader(line: rom)
    box.task = Task { try await bootloader.connect() }
    await #expect(throws: CancellationError.self) { try await box.task!.value }
    #expect(await rom.mode == .app)
    #expect(await (rom.dtr, rom.rts) == (false, false))
    #expect(await rom.resets == 1)
}
