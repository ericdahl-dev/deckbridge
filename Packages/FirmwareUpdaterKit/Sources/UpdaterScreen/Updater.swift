import DeviceFinder
import Foundation
import Observation
import PanelFlasher
import PortHandoff

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

/// The app's model (#688): finds what is plugged in, and looks again when USB changes, so a newly installed driver
/// shows without a restart. Looks never overlap: one asked for during a look runs once, after it.
@MainActor @Observable
public final class Updater {
    public private(set) var screen = UpdaterScreen(found: Found(), lc6000WarningAccepted: false)
    public private(set) var looking = false
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
    /// `borrow`: asks DeckBridge for the panel's port (#710). `flasher`: puts the catalog's newest image on the panel
    /// over its cable (#687); nil, the app offers no update.
    public init(finder: DeviceFinder, changes: AsyncStream<Void>, clock: any UpdaterClock = SystemClock(),
                log: (any LogSink)? = nil, borrow: (@Sendable () -> PortBorrow)? = nil,
                flasher: (any PanelFlashing)? = nil) {
        self.finder = finder
        self.changes = changes
        self.clock = clock
        self.log = log
        self.borrow = borrow
        self.flasher = flasher
    }

    private let borrow: (@Sendable () -> PortBorrow)?
    private let flasher: (any PanelFlashing)?
    /// What the update over the cable says now; nil before the first one.
    private var updateText: String?

    /// Updates the panel over its cable (#687). DeckBridge is asked for the port first (#710). With no answer (it isn't
    /// running, or it's from before #710) the port is tried anyway; only a busy port then says to free it by hand.
    public func updatePanel() async {
        guard let flasher else { return }
        let lend = borrow?()
        let outcome = await lend?.borrow() ?? .noAnswer
        let (steps, step) = AsyncStream<PanelUpdate.Step>.makeStream()
        Task.detached {
            await flasher.flash { step.yield($0) }
            step.finish()
        }
        for await next in steps {
            if case .failed(.portBusy) = next, let text = UpdaterScreen.handoff(outcome) {
                updateText = text
            } else {
                updateText = next.text
            }
            show()
        }
        lend?.giveBack()
        // The panel restarted into its new build: look again so the section shows it.
        await refresh()
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

    /// Looks again on every USB change, until the stream ends.
    public func watch() async {
        for await _ in changes { await refresh() }
    }

    public func acceptLC6000Warning() {
        lc6000WarningAccepted = true
        show()
    }

    private func show() {
        screen = UpdaterScreen(found: found, lc6000WarningAccepted: lc6000WarningAccepted, panelWaiting: waitingForPort,
                               update: updateText)
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
