import DeviceFinder
import Foundation
import Testing
import UpdaterScreen

/// A USB list that takes a moment to read and counts how many reads run at once.
final class SlowUSB: USBDevices, @unchecked Sendable {
    let lock = NSLock()
    var plugged: [USBDevice] = []
    private var inFlight = 0
    private(set) var mostAtOnce = 0
    private(set) var reads = 0

    func devices() async -> [USBDevice] {
        lock.withLock { inFlight += 1; reads += 1; mostAtOnce = max(mostAtOnce, inFlight) }
        try? await Task.sleep(for: .milliseconds(20))
        return lock.withLock { inFlight -= 1; return plugged }
    }
}

/// A clock the test runs: a sleep moves its time on at once, and records how long it was asked for.
final class FakeClock: UpdaterClock, @unchecked Sendable {
    var now = 0.0
    var sleeps: [Double] = []
    func sleep(for seconds: Double) async {
        sleeps.append(seconds)
        now += seconds
    }
}

/// The app's model (#688): it looks again by itself when USB changes, so a newly installed driver shows without a restart.
@Suite("Updater: looks again when USB changes")
@MainActor
struct UpdaterTests {
    static let port = "/dev/cu.wchusbserial210"
    static let noDriver = USBDevice(vendor: 0x1A86, product: 0x7522, name: "USB Serial")
    static let withDriver = USBDevice(vendor: 0x1A86, product: 0x7522, name: "USB Serial", serialPort: port)

    @Test("After the driver is installed and the panel replugged, a USB change shows its build, with no restart")
    func refindsOnUSBChange() async {
        let rig = Rig()
        rig.usb.plugged = [Self.noDriver]
        let (changes, change) = AsyncStream<Void>.makeStream()
        let updater = Updater(finder: rig.finder, changes: changes, clock: FakeClock())
        await updater.refresh()
        await updater.pendingLook?.value
        #expect(updater.screen.panel.guide != nil)

        rig.usb.plugged = [Self.withDriver]
        rig.serial.lines[Self.port] = ["deck panel: boot, build 1d0683f"]
        change.yield()
        change.finish()
        await updater.watch()
        #expect(updater.screen.panel.detail == "Build 1d0683f")
        #expect(updater.screen.panel.guide == nil)
    }

    @Test("Looks asked for while one runs never overlap, and one more look reads what changed meanwhile")
    func looksNeverOverlap() async {
        let rig = Rig()
        let usb = SlowUSB()
        usb.plugged = [Self.noDriver]
        let finder = DeviceFinder(usb: usb, midi: rig.midi, serial: rig.serial, log: rig.log)
        let updater = Updater(finder: finder, changes: AsyncStream { $0.finish() })

        async let first: Void = updater.refresh()
        await Task.yield()
        usb.lock.withLock { usb.plugged = [] }
        async let second: Void = updater.refresh()
        async let third: Void = updater.refresh()
        _ = await (first, second, third)

        #expect(usb.mostAtOnce == 1)
        #expect(usb.reads == 2)
        #expect(updater.screen.panel.status == "Nothing connected")
    }

    @Test("Accepting the LC6000 warning shows the LC6000 section without looking again")
    func acceptWarning() async {
        let rig = Rig()
        rig.midi.ports = ["LC6000 PRIME Controller"]
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() })
        await updater.refresh()
        #expect(updater.screen.lc6000.status == "Read the warning first")
        updater.acceptLC6000Warning()
        #expect(updater.screen.lc6000.status == "LC6000 found")
    }

    @Test("The panel on USB with no port yet: waiting for its port, no guide; still none 10 s on: the driver is missing")
    func waitsForThePortBeforeDriverMissing() async {
        let rig = Rig()
        rig.usb.plugged = [Self.noDriver]
        let clock = FakeClock()
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, clock: clock)
        await updater.refresh()
        #expect(updater.screen.panel.status == "Deck panel found")
        #expect(updater.screen.panel.detail == "Waiting for its port")
        #expect(updater.screen.panel.guide == nil)
        await updater.pendingLook?.value
        #expect(clock.sleeps == [10])
        #expect(updater.screen.panel.detail == "The USB driver for its chip is missing")
        #expect(updater.screen.panel.guide == .ch34x)
    }
}
