import DeviceFinder
import FirmwareModel
import Foundation
import Testing
@testable import PanelFlasher

final class FakeOpener: LineOpener, @unchecked Sendable {
    let rom: FakeROM
    var busy = false
    var opened: [String] = []
    init(rom: FakeROM) { self.rom = rom }
    func open(_ port: String) async throws -> any BootloaderLine {
        opened.append(port)
        if busy { throw FlashError.portBusy }
        return rom
    }
}

/// The panel after its restart: on USB with its serial port, printing the new build's boot line.
final class Plugged: USBDevices, MIDIPorts, PanelSerial, LogSink, @unchecked Sendable {
    var bootLine = "deck panel: boot, build 1d0683f, version 1.1.0"
    func devices() async -> [USBDevice] { [USBDevice(vendor: 0x1A86, product: 0x7522, name: "USB Serial", serialPort: "/dev/cu.panel")] }
    func names() async -> [String] { [] }
    func listen(on port: String, baud: Int, for seconds: Double) async -> Listened { .lines([bootLine]) }
    func log(_ line: String) {}
}

final class Steps: @unchecked Sendable {
    var seen: [PanelUpdate.Step] = []
    var withoutProgress: [PanelUpdate.Step] { seen.filter { if case .writing = $0 { false } else { true } } }
}

private let app = panelApp(count: 3000)

private func run(_ rom: FakeROM, busy: Bool = false, image: [UInt8] = app) async -> (Steps, FakeOpener) {
    let opener = FakeOpener(rom: rom)
    opener.busy = busy
    let plugged = Plugged()
    let update = PanelUpdate(opener: opener, finder: DeviceFinder(usb: plugged, midi: plugged, serial: plugged, log: plugged))
    let steps = Steps()
    await update.run(image, on: "/dev/cu.panel", wipeWiFi: false) { steps.seen.append($0) }
    return (steps, opener)
}

private func deckPanel() async -> FakeROM {
    let rom = FakeROM()
    await rom.setFlash(deckPanelPartitionTable(), at: 0x8000)
    return rom
}

@Test func anUpdateRunsThroughToTheBuildThePanelNowShows() async throws {
    let rom = await deckPanel()
    let (steps, _) = await run(rom)
    #expect(steps.withoutProgress == [.connecting, .restarting, .done(PanelBuild(sha: "1d0683f", version: FirmwareVersion("1.1.0")))])
    #expect(steps.seen.contains(.writing(1.0)))
    #expect(await rom.flashBytes(at: 0x10000, count: app.count) == app)
    #expect(await rom.mode == .app)
    #expect(await rom.closed)
}

/// DeckBridge holds the cable (it opens it exclusively while sending over it): stop, say so, touch nothing.
@Test func aCableDeckBridgeHoldsStopsTheUpdateBeforeAnything() async throws {
    let rom = await deckPanel()
    let (steps, _) = await run(rom, busy: true)
    #expect(steps.seen == [.connecting, .failed(.portBusy)])
    #expect(await rom.received.isEmpty)
}

@Test func aWrongBoardIsRefusedWithNothingWrittenAndTheLineClosed() async throws {
    let rom = await deckPanel()
    await rom.setChipID(5)
    let (steps, _) = await run(rom)
    #expect(steps.seen == [.connecting, .failed(.wrongBoard("chip id 5"))])
    #expect(await rom.begun.isEmpty)
    #expect(await rom.closed)
}

@Test func aFailedWriteEndsTheUpdateWithTheLineClosedAndThePanelRunning() async throws {
    let rom = await deckPanel()
    await rom.setFailingBlock(1)
    let (steps, _) = await run(rom)
    #expect(steps.withoutProgress == [.connecting, .failed(.writeFailed(address: 0x10400))])
    #expect(await rom.mode == .app)
    #expect(await rom.closed)
}

/// The cable comes out (or the port fails): the update ends saying the panel was lost, and the line is closed.
@Test func aLineThatFailsIsALostPanel() async throws {
    let rom = await deckPanel()
    await rom.unplug()
    let (steps, _) = await run(rom)
    #expect(steps.seen == [.connecting, .failed(.lineLost)])
    #expect(await rom.closed)
}

/// The image itself is checked before the cable is opened: an ESP32-S3 app image (magic E9, chip id 9) that fits app0
/// (0x640000), so a wrong or oversized file can never erase into app1.
@Test(arguments: [
    [0x00] + Array(panelApp(count: 3000).dropFirst()),
    { var b = panelApp(count: 3000); b[12] = 0x05; return b }(),
    panelApp(count: 0x64_0001),
    [UInt8](),
])
func anImageThatIsNotAPanelAppIsRefusedBeforeTheCableIsOpened(image: [UInt8]) async throws {
    let rom = await deckPanel()
    let (steps, opener) = await run(rom, image: image)
    #expect(steps.seen == [.failed(.notAPanelImage)])
    #expect(opener.opened.isEmpty)
}

/// The owner cancels once writing has begun: app0 may be half written, so the owner is told the panel may not start,
/// and it is still reset into whatever it boots.
@Test func cancellingMidWriteSaysThePanelMayNotStart() async throws {
    let rom = await deckPanel()
    let box = FlowBox()
    await rom.setAfterBlock { seq in if seq == 1 { box.task?.cancel() } }
    let plugged = Plugged()
    let update = PanelUpdate(opener: FakeOpener(rom: rom), finder: DeviceFinder(usb: plugged, midi: plugged, serial: plugged, log: plugged))
    let steps = Steps()
    box.task = Task { await update.run(app, on: "/dev/cu.panel", wipeWiFi: false) { steps.seen.append($0) } }
    _ = await box.task?.result
    #expect(steps.withoutProgress.last == .failed(.cancelledWhileWriting))
    #expect(await rom.mode == .app)
    #expect(await rom.closed)
}

/// However an update ends, the panel is reset into its app once, not once per layer that saw the failure.
@Test func aFailedUpdateResetsThePanelIntoItsAppOnce() async throws {
    let rom = await deckPanel()
    await rom.setFailingBlock(1)
    _ = await run(rom)
    #expect(await rom.appBoots == 1)
}
