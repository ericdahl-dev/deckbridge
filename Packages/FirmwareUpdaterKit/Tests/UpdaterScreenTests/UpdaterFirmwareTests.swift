import DeviceFinder
import Foundation
import Testing
import UpdaterScreen

/// Counts how often the firmware line was asked for, and answers with a fixed one.
final class FakeFirmwareSource: @unchecked Sendable {
    let lock = NSLock()
    let line: FirmwareLine
    private(set) var asked = 0
    init(_ line: FirmwareLine) { self.line = line }
    func fetch() async -> FirmwareLine {
        lock.withLock { asked += 1 }
        return line
    }
}

/// The firmware the updater offers (#704): fetched once on launch, shown in its own line, apart from the devices.
@Suite("Updater: the firmware it offers")
@MainActor
struct UpdaterFirmwareTests {
    static let builtIn = FirmwareLine(source: "Firmware built into this app: deck panel 1.0.0",
                                      reason: "GitHub couldn't be reached, so the firmware built into this app is offered.")

    @Test("On launch the updater fetches the firmware line once and shows it in its own field")
    func loadsTheLineOnce() async {
        let rig = Rig()
        let source = FakeFirmwareSource(Self.builtIn)
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, firmware: source.fetch)
        #expect(updater.firmware == nil)
        await updater.loadFirmware()
        #expect(updater.firmware == Self.builtIn)
        #expect(source.asked == 1)
        #expect(updater.screen.panel.detail == nil)
    }
}
