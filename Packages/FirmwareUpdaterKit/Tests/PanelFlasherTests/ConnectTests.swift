import Testing
@testable import PanelFlasher

final class TaskBox: @unchecked Sendable { var task: Task<Void, Error>? }
final class FlowBox: @unchecked Sendable { var task: Task<Void, Never>? }

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

/// esptool's connect alternates how long it lets the chip come out of reset, 0.05 s then 0.55 s (loader.py
/// _construct_reset_strategy_sequence), since boards' EN circuits differ.
@Test func eachAttemptAlternatesAShortAndALongResetDelay() async throws {
    let rom = FakeROM()
    await rom.setAnswers(false)
    let bootloader = Bootloader(line: rom)
    await #expect(throws: FlashError.noBootloader) { try await bootloader.connect() }
    let delays = await rom.pauses.filter { $0.dtr && !$0.rts }.map(\.seconds)
    #expect(delays == [0.05, 0.55, 0.05, 0.55, 0.05, 0.55, 0.05])
}
