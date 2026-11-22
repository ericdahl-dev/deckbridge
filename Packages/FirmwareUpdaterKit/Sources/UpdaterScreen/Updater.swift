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
    private var firmwareAsked = false
    private var lookAgain = false
    private var found = Found()
    private var lc6000WarningAccepted = false
    private let finder: DeviceFinder
    private let changes: AsyncStream<Void>
    private let clock: any UpdaterClock
    private let log: (any LogSink)?
    /// Asks DeckBridge for the panel's port when it holds it for the cable feed (#710); nil never asks.
    private let borrow: (@Sendable () -> PortBorrow)?
    /// DeckBridge held the port and didn't answer when asked for it, in the last look.
    private var deckBridgeSilent = false
    /// How long the panel may be on USB with no serial port before its driver is called missing (#700's owner run):
    /// WCH's driver extension makes the port about 6 s after the USB device appears.
    public static let portWait = 10.0
    /// When the panel was first seen on USB with no port, in this plug; nil while it has one or isn't plugged in.
    private var noPortSince: Double?
    /// The look at the end of the wait for the port; nil when none is due.
    public private(set) var pendingLook: Task<Void, Never>?

    /// `changes` yields when a USB device arrives or leaves, or a serial port appears.
    /// `log`: the finder's log, for the line when the wait for the port is up.
    /// `borrow`: a new borrow of the panel's port from DeckBridge, used when a look finds the port busy, and by an
    /// update over the cable (#710). `flasher`: puts the catalog's newest image on the panel over its cable (#687);
    /// nil, the app offers no update.
    public init(finder: DeviceFinder, changes: AsyncStream<Void>, clock: any UpdaterClock = SystemClock(),
                log: (any LogSink)? = nil, borrow: (@Sendable () -> PortBorrow)? = nil,
                firmware: (@Sendable () async -> FirmwareLine)? = nil, flasher: (any PanelFlashing)? = nil) {
        self.finder = finder
        self.fetchFirmware = firmware
        self.changes = changes
        self.clock = clock
        self.log = log
        self.borrow = borrow
        self.flasher = flasher
    }

    private let flasher: (any PanelFlashing)?
    /// What the update over the cable says now; nil before the first one.
    private var updateText: String?
    /// An update over the cable is running: one at a time, and no looks meanwhile.
    public private(set) var updating = false
    private var flashing: Task<Void, Never>?

    /// The update offered for the panel's build, when the panel told it and the catalog has one newer.
    private var offer: PanelUpdateOffer? {
        guard let flasher, case .onSerial(let build?) = found.panel else { return nil }
        return flasher.offer(for: build)
    }

    /// The update can still be stopped: only before the first erase. The panel has one app slot (until #690), so a
    /// stop once it's being written would leave it unable to start (#744's live run).
    public private(set) var canCancel = false

    /// The repair offered for a panel whose port is there but whose build can't be read (#744): it may not be starting,
    /// or it may run firmware from before #702. The ROM bootloader is there either way.
    private var repair: PanelUpdateOffer? {
        guard let flasher, case .onSerial(nil) = found.panel, let version = flasher.repairVersion() else { return nil }
        return PanelUpdateOffer(version: version, note: nil)
    }

    /// Repairs the panel: the catalog's image, written the same way as an update (after the owner confirms).
    public func repairPanel() async { await updatePanel() }

    /// Stops the update before it writes: the flasher resets the panel into its app. Once writing has begun, nothing.
    public func cancelUpdate() {
        guard canCancel else { return }
        flashing?.cancel()
    }

    /// Updates the panel over its cable (#687). DeckBridge is asked for the port first (#710). With no answer (it isn't
    /// running, or it's from before #710) the port is tried anyway; only a busy port then says to free it by hand.
    public func updatePanel() async {
        guard let flasher, !updating else { return }
        updating = true
        canCancel = true
        let lend = borrow?()
        let outcome = if let lend { await ask(lend) } else { PortBorrow.Outcome.noAnswer }
        let (steps, step) = AsyncStream<PanelUpdate.Step>.makeStream()
        flashing = Task.detached {
            await flasher.flash { step.yield($0) }
            step.finish()
        }
        for await next in steps {
            if case .writing = next { canCancel = false }
            if case .failed(.portBusy) = next, let text = UpdaterScreen.handoff(outcome) {
                updateText = text
            } else {
                updateText = next.text
            }
            show()
        }
        if let lend { giveBack(lend, after: outcome) }
        flashing = nil
        canCancel = false
        updating = false
        // The panel restarted into its new build: look again so the section shows it, keeping the result on screen.
        await look(keepingResult: true)
    }

    /// A look the owner asked for (Look again) or launch's: the last update's result goes (#762: one status line per
    /// step). A USB change keeps it: the panel's port comes back seconds after an update, and the result must stay.
    public func refresh() async { await look(keepingResult: false) }

    private func look(keepingResult: Bool) async {
        // During an update the panel restarts (a USB change), and a look would open the port the flasher holds. The
        // update looks once when it's done.
        guard !updating else { return }
        guard !looking else {
            lookAgain = true
            return
        }
        looking = true
        if !keepingResult { updateText = nil }
        repeat {
            lookAgain = false
            found = await finder.find()
            await lookPastDeckBridge()
            watchForPort()
            show()
        } while lookAgain
        looking = false
    }

    /// Fetches the firmware line, once: for launch. Looking again never fetches it (one GitHub request per launch).
    public func loadFirmware() async {
        guard let fetchFirmware, !firmwareAsked else { return }
        firmwareAsked = true
        firmware = await fetchFirmware()
    }

    /// Looks again on every USB change, until the stream ends.
    public func watch() async {
        for await _ in changes { await look(keepingResult: true) }
    }

    public func acceptLC6000Warning() {
        lc6000WarningAccepted = true
        show()
    }

    private func show() {
        screen = UpdaterScreen(found: found, lc6000WarningAccepted: lc6000WarningAccepted, panelWaiting: waitingForPort,
                               deckBridgeSilent: deckBridgeSilent, update: updateText, panelUpdate: offer, panelRepair: repair,
                               writing: updating && !canCancel)
    }

    /// The panel's port busy: DeckBridge holds it for the cable feed. Ask for it, look while it's lent, give it back.
    /// With no answer nothing is forced; the screen says how to free it.
    private func lookPastDeckBridge() async {
        deckBridgeSilent = false
        guard case .portBusy = found.panel, let borrow = borrow?() else { return }
        switch await ask(borrow) {
        case .lent:
            found = await finder.find()
            giveBack(borrow)
        case .noAnswer:
            deckBridgeSilent = true
        }
    }

    /// Asks DeckBridge for the port, and logs its answer (#710: the owner's run had no trace of either side).
    private func ask(_ borrow: PortBorrow) async -> PortBorrow.Outcome {
        let outcome = await borrow.borrow()
        switch outcome {
        case .lent: log?.log("deck panel: asked DeckBridge for the port, it let go")
        case .noAnswer: log?.log("deck panel: asked DeckBridge for the port, no answer in \(Int(PortBorrow.answerWait)) s")
        }
        return outcome
    }

    /// Gives a lent port back, and logs it; nothing when it wasn't lent.
    private func giveBack(_ borrow: PortBorrow, after outcome: PortBorrow.Outcome = .lent) {
        borrow.giveBack()
        if outcome == .lent { log?.log("deck panel: gave the port back to DeckBridge") }
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
