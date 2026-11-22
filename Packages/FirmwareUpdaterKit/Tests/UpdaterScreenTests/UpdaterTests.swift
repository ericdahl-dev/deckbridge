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

/// A clock the test runs: a sleep waits until the test lets the time pass, then moves the clock on by it.
final class FakeClock: UpdaterClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    private var passed = false
    private var waiting: [(Double, CheckedContinuation<Void, Never>)] = []
    private(set) var sleeps: [Double] = []
    var now: Double { lock.withLock { time } }

    func sleep(for seconds: Double) async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                sleeps.append(seconds)
                if passed { time += seconds; return true }
                waiting.append((seconds, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Every sleep asked for, and any asked for from now on, is over.
    func pass() {
        let woken = lock.withLock {
            passed = true
            for (seconds, _) in waiting { time += seconds }
            defer { waiting = [] }
            return waiting.map(\.1)
        }
        for continuation in woken { continuation.resume() }
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
        let clock = FakeClock()
        let updater = Updater(finder: rig.finder, changes: changes, clock: clock)
        await updater.refresh()
        clock.pass()
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
        clock.pass()
        await updater.pendingLook?.value
        #expect(clock.sleeps == [10])
        #expect(updater.screen.panel.detail == "The USB driver for its chip is missing")
        #expect(updater.screen.panel.guide == .ch34x)
    }

    @Test("The port comes inside the wait: the build shows, the guide never does, and the look at 10 s is called off")
    func portInsideTheWait() async {
        let rig = Rig()
        rig.usb.plugged = [Self.noDriver]
        let clock = FakeClock()
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, clock: clock)
        await updater.refresh()
        let look = updater.pendingLook
        rig.usb.plugged = [Self.withDriver]
        rig.serial.lines[Self.port] = ["deck panel: boot, build 1d0683f"]
        await updater.refresh()  // the serial port's notification
        #expect(updater.screen.panel.detail == "Build 1d0683f")
        let opened = rig.serial.opened.count
        clock.pass()
        await look?.value
        #expect(rig.serial.opened.count == opened)  // no look at 10 s: it would listen on the panel again
        #expect(updater.screen.panel.guide == nil)
    }

    @Test("Unplugged and plugged in again: the wait for the port starts over")
    func replugWaitsAgain() async {
        let rig = Rig()
        rig.usb.plugged = [Self.noDriver]
        let clock = FakeClock()
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, clock: clock)
        await updater.refresh()
        clock.pass()
        await updater.pendingLook?.value
        #expect(updater.screen.panel.guide == .ch34x)
        rig.usb.plugged = []
        await updater.refresh()
        rig.usb.plugged = [Self.noDriver]
        await updater.refresh()
        #expect(updater.screen.panel.detail == "Waiting for its port")
    }
}
