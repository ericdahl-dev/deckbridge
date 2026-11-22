import DeviceFinder
import FirmwareModel
import Foundation
import Testing
@testable import PanelFlasher

// A blank or foreign ESP32-S3 board made a deck panel (#687): only when the owner confirmed it, with the panel build's
// bootloader and partition table, the whole set `pio upload` writes, and nothing of the board's old settings kept.

private let app = panelApp(count: 3000)
private let loader: [UInt8] = [0xE9] + (1..<1500).map { UInt8(truncatingIfNeeded: $0 * 3) }

private func foreignBoard() async -> FakeROM {
    let rom = FakeROM()
    await rom.setFlash([0xAA, 0x50, 0x01, 0x02, 0x00, 0x90], at: 0x8000)  // another layout
    await rom.setFlash(Array("someone else's settings".utf8), at: 0x9000)
    return rom
}

private func run(_ rom: FakeROM, makeDeckPanel: Bool) async -> [PanelUpdate.Step] {
    let plugged = Plugged()
    let update = PanelUpdate(opener: FakeOpener(rom: rom), finder: DeviceFinder(usb: plugged, midi: plugged, serial: plugged, log: plugged))
    let steps = Steps()
    await update.run(app, on: "/dev/cu.panel", wipeWiFi: false,
                     boot: .init(bootloader: loader, partitions: deckPanelPartitionTable()), makeDeckPanel: makeDeckPanel) {
        steps.seen.append($0)
    }
    return steps.withoutProgress
}

@Test func aForeignBoardTheOwnerConfirmedIsMadeADeckPanel() async throws {
    let rom = await foreignBoard()
    let steps = await run(rom, makeDeckPanel: true)
    #expect(steps.last.map { if case .done = $0 { true } else { false } } == true)
    #expect(await rom.flashBytes(at: 0x0, count: loader.count) == loader)
    #expect(await rom.flashBytes(at: 0x8000, count: 3072) == deckPanelPartitionTable())
    #expect(await rom.flashBytes(at: 0x10000, count: app.count) == app)
    #expect(await rom.flashBytes(at: 0x9000, count: 0x5000).allSatisfy { $0 == 0xFF })
    #expect(await rom.begun.map(\.offset) == [0x0, 0x8000, 0x10000, 0xE000, 0x9000])
}

@Test func withoutTheOwnersConfirmationAForeignBoardIsRefusedWithNothingWritten() async throws {
    let rom = await foreignBoard()
    let steps = await run(rom, makeDeckPanel: false)
    #expect(steps == [.connecting, .failed(.notADeckPanel)])
    #expect(await rom.begun.isEmpty)
}

/// A board that is already a deck panel gets a plain update: its bootloader and saved Wi-Fi stay.
@Test func aDeckPanelIsOnlyUpdatedEvenWhenTheOwnerConfirmed() async throws {
    let rom = FakeROM()
    await rom.setFlash(deckPanelPartitionTable(), at: 0x8000)
    await rom.setFlash(Array("saved Wi-Fi".utf8), at: 0x9000)
    _ = await run(rom, makeDeckPanel: true)
    #expect(await rom.begun.map(\.offset) == [0x10000, 0xE000])
}

@Test func aWrongChipIsRefusedEvenWhenTheOwnerConfirmed() async throws {
    let rom = await foreignBoard()
    await rom.setChipID(5)
    let steps = await run(rom, makeDeckPanel: true)
    #expect(steps == [.connecting, .failed(.wrongBoard("chip id 5"))])
    #expect(await rom.begun.isEmpty)
}
