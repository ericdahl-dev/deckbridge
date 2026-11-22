import DeviceFinder
import Foundation
import Observation

/// The time, and a wait: the real one in the app, a fake in tests.
public protocol UpdaterClock: Sendable {
    var now: Double { get }
    func sleep(for seconds: Double) async
}

/// The Mac's clock: seconds since boot.
public struct SystemClock: UpdaterClock {
    public init() {}
    public var now: Double { ProcessInfo.processInfo.systemUptime }
    public func sleep(for seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
}

/// The firmware the updater offers (#704), as the screen says it: where it comes from, and why the newest release
/// wasn't used (nil when it was). Plain words, so this target never sees the release code.
public struct FirmwareLine: Equatable, Sendable {
    public let source: String
    public let reason: String?

    public init(source: String, reason: String?) {
        self.source = source
        self.reason = reason
    }
}

/// The app's model (#688): finds what is plugged in, and looks again when USB changes, so a newly installed driver
/// shows without a restart. Looks never overlap: one asked for during a look runs once, after it.
@MainActor @Observable
public final class Updater {
    public private(set) var screen = UpdaterScreen(found: Found(), lc6000WarningAccepted: false)
    public private(set) var looking = false
    /// The firmware offered (#704): nil until `loadFirmware()` has its answer. Its own line, never a device's detail.
    public private(set) var firmware: FirmwareLine?
    private let fetchFirmware: (@Sendable () async -> FirmwareLine)?
    private var lookAgain = false
    private var found = Found()
    private var lc6000WarningAccepted = false
    private let finder: DeviceFinder
    private let changes: AsyncStream<Void>
    private let clock: any UpdaterClock
    private let log: (any LogSink)?
    /// How long the panel may be on USB with no serial port before its driver is called missing (#700's owner run):
    /// WCH's driver extension makes the port about 6 s after the USB device appears.
    public static let portWait = 10.0
    /// When the panel was first seen on USB with no port, in this plug; nil while it has one or isn't plugged in.
    private var noPortSince: Double?
    /// The look at the end of the wait for the port; nil when none is due.
    public private(set) var pendingLook: Task<Void, Never>?

    /// `changes` yields when a USB device arrives or leaves, or a serial port appears.
    /// `log`: the finder's log, for the line when the wait for the port is up.
    public init(finder: DeviceFinder, changes: AsyncStream<Void>, clock: any UpdaterClock = SystemClock(),
                log: (any LogSink)? = nil, firmware: (@Sendable () async -> FirmwareLine)? = nil) {
        self.finder = finder
        self.fetchFirmware = firmware
        self.changes = changes
        self.clock = clock
        self.log = log
    }

    public func refresh() async {
        guard !looking else {
            lookAgain = true
            return
        }
        looking = true
        repeat {
            lookAgain = false
            found = await finder.find()
            watchForPort()
            show()
        } while lookAgain
        looking = false
    }

    /// Fetches the firmware line, for launch.
    public func loadFirmware() async {
        guard let fetchFirmware else { return }
        firmware = await fetchFirmware()
    }

    /// Looks again on every USB change, until the stream ends.
    public func watch() async {
        for await _ in changes { await refresh() }
    }

    public func acceptLC6000Warning() {
        lc6000WarningAccepted = true
        show()
    }

    private func show() {
        screen = UpdaterScreen(found: found, lc6000WarningAccepted: lc6000WarningAccepted, panelWaiting: waitingForPort)
    }

    /// The panel is on USB with no port, and the wait isn't up: it may still be coming.
    private var waitingForPort: Bool {
        guard case .driverMissing = found.panel, let since = noPortSince else { return false }
        return clock.now - since < Self.portWait
    }

    /// Starts the wait for the port when the panel first shows on USB without one, with a look at its end. A port, or
    /// the panel unplugged, ends the wait and calls the look off; the next plug waits again.
    private func watchForPort() {
        guard case .driverMissing = found.panel else {
            noPortSince = nil
            pendingLook?.cancel()
            pendingLook = nil
            return
        }
        guard noPortSince == nil else { return }
        noPortSince = clock.now
        pendingLook = Task { [clock] in
            await clock.sleep(for: Self.portWait)
            guard !Task.isCancelled else { return }
            await self.refresh()
            // Still no port: the log says so as the screen does, once.
            if case .driverMissing = self.found.panel {
                self.log?.log("deck panel: on USB \(DeviceFinder.panelUSBID), no serial port after 10 s (driver missing)")
            }
        }
    }
}
