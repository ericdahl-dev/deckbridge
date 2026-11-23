import DeviceFinder
import FirmwareModel
import PanelFlasher
import PortHandoff
import Synchronization
import Testing
import UpdaterScreen

/// DeckBridge at the other end of the port handoff (#710): answers "released" when `answers`; never, when it isn't
/// running or is from before #710.
final class StubDeckBridge: HandoffChannel, @unchecked Sendable {
    let answers: Bool
    private let state = Mutex<(posted: [HandoffSignal], heard: [AsyncStream<HandoffSignal>.Continuation])>(([], []))
    var posted: [HandoffSignal] { state.withLock { $0.posted } }

    init(answers: Bool) { self.answers = answers }

    func listen() -> AsyncStream<HandoffSignal> {
        let (stream, continuation) = AsyncStream<HandoffSignal>.makeStream()
        state.withLock { $0.heard.append(continuation) }
        return stream
    }

    func post(_ signal: HandoffSignal) {
        let heard = state.withLock { $0.posted.append(signal); return $0.heard }
        if signal == .release, answers { for listener in heard { listener.yield(.released) } }
    }

    /// The wait for an answer: none when it won't come, and long enough that an answer always wins when it will.
    func borrow() -> PortBorrow {
        let answers = answers
        return PortBorrow(channel: self, sleep: { _ in if answers { try? await Task.sleep(for: .seconds(10)) } })
    }
}

/// The flasher (#687) as the updater sees it: it reports these steps, as PanelUpdate would.
final class StubFlasher: PanelFlashing, @unchecked Sendable {
    let steps: [PanelUpdate.Step]
    var offered: PanelUpdateOffer? = PanelUpdateOffer(version: "1.3.0", note: nil)
    private(set) var asked: [PanelBuild] = []

    func offer(for build: PanelBuild) -> PanelUpdateOffer? {
        asked.append(build)
        return offered
    }

    var repairable: String? = "1.3.0"
    func repairVersion() -> String? { repairable }
    private let runs = Mutex(0)
    var started: Int { runs.withLock { $0 } }

    init(_ steps: [PanelUpdate.Step]) { self.steps = steps }

    func flash(report: @escaping @Sendable (PanelUpdate.Step) -> Void) async {
        runs.withLock { $0 += 1 }
        for step in steps { report(step) }
    }
}

/// A flasher that reports `first`, then holds until the test finishes it or the update is canceled, and says which.
final class HeldFlasher: PanelFlashing, @unchecked Sendable {
    let first: PanelUpdate.Step
    private let state = Mutex((runs: 0, holding: false, finished: false, sawCancel: false))
    var started: Int { state.withLock { $0.runs } }
    var holding: Bool { state.withLock { $0.holding } }
    var sawCancel: Bool { state.withLock { $0.sawCancel } }

    init(first: PanelUpdate.Step) { self.first = first }

    func offer(for build: PanelBuild) -> PanelUpdateOffer? { nil }
    func repairVersion() -> String? { nil }
    func finish() { state.withLock { $0.finished = true } }

    func flash(report: @escaping @Sendable (PanelUpdate.Step) -> Void) async {
        state.withLock { $0.runs += 1 }
        report(first)
        state.withLock { $0.holding = true }
        while !state.withLock({ $0.finished }) && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        if Task.isCancelled {
            state.withLock { $0.sawCancel = true }
            report(.failed(.canceled))
        } else {
            report(Self.done)
        }
    }

    static let done = PanelUpdate.Step.done(PanelBuild(sha: "2b7e9c1"))
}

/// Updating the panel over its cable from the app (#687), with DeckBridge asked for the port first (#710).
@Suite("Updater: updating the deck panel over its cable")
@MainActor
struct PanelUpdateFlowTests {
    static let updated = PanelUpdate.Step.done(PanelBuild(sha: "2b7e9c1"))

    static func updater(_ deckBridge: StubDeckBridge, _ flasher: StubFlasher) -> Updater {
        Updater(finder: Rig().finder, changes: AsyncStream { $0.finish() }, borrow: deckBridge.borrow, flasher: flasher)
    }

    @Test("DeckBridge doesn't answer and the port is busy: say so, and nothing more is tried")
    func noAnswerAndBusy() async {
        let flasher = StubFlasher([.connecting, .failed(.portBusy)])
        let updater = Self.updater(StubDeckBridge(answers: false), flasher)
        await updater.updatePanel()
        #expect(updater.screen.update == UpdaterScreen.deckBridgeNoAnswer)
        #expect(flasher.started == 1)
    }

    @Test("DeckBridge isn't running (no answer) and the port is free: the update goes ahead")
    func noAnswerButFree() async {
        let updater = Self.updater(StubDeckBridge(answers: false), StubFlasher([.connecting, .restarting, Self.updated]))
        await updater.updatePanel()
        #expect(updater.screen.update == "Updated: the panel now runs build 2b7e9c1")
    }

    @Test("DeckBridge lets go: the update runs, the port goes back to it once, and a fresh look shows the new build")
    func lent() async {
        let rig = Rig()
        UpdaterScreenTests.panel(rig, printing: ["deck panel: boot, build 2b7e9c1"])
        let deckBridge = StubDeckBridge(answers: true)
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, borrow: deckBridge.borrow,
                              flasher: StubFlasher([.connecting, .writing(0.5), .restarting, Self.updated]))
        await updater.updatePanel()
        #expect(deckBridge.posted == [.release, .done])
        #expect(updater.screen.update == "Updated: the panel now runs build 2b7e9c1")
        #expect(updater.screen.panel.detail == "Build 2b7e9c1")
    }

    @Test("A write that stops partway: the screen has no address, the log has it (#763)")
    func writeFailedAddressInLogOnly() async {
        let rig = Rig()
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, log: rig.log,
                              borrow: StubDeckBridge(answers: true).borrow,
                              flasher: StubFlasher([.connecting, .writing(0.3), .failed(.writeFailed(address: 0x10400))]))
        await updater.updatePanel()
        #expect(updater.screen.update == "Writing stopped partway. The panel may not start: try again before you unplug it.")
        #expect(rig.log.lines.contains("deck panel: writing stopped at 0x10400"))
    }

    @Test("A failure: its text shows, the port still goes back once, and the next update can start")
    func failure() async {
        let deckBridge = StubDeckBridge(answers: true)
        let flasher = StubFlasher([.connecting, .failed(.verifyFailed(address: 0x10000))])
        let updater = Self.updater(deckBridge, flasher)
        await updater.updatePanel()
        #expect(updater.screen.update == "The written firmware didn't check out. The panel may not start: try again before you unplug it.")
        #expect(deckBridge.posted == [.release, .done])
        await updater.updatePanel()
        #expect(flasher.started == 2)
    }

    static func held(_ flasher: HeldFlasher, _ deckBridge: StubDeckBridge = StubDeckBridge(answers: true),
                     finder: DeviceFinder = Rig().finder) async -> (Updater, Task<Void, Never>) {
        let updater = Updater(finder: finder, changes: AsyncStream { $0.finish() }, borrow: deckBridge.borrow, flasher: flasher)
        let run = Task { await updater.updatePanel() }
        while !flasher.holding { try? await Task.sleep(for: .milliseconds(5)) }
        return (updater, run)
    }

    @Test("Cancel before writing: offered, the flasher stops, says so, and the port goes back")
    func cancelBeforeWriting() async {
        let deckBridge = StubDeckBridge(answers: true)
        let flasher = HeldFlasher(first: .connecting)
        let (updater, run) = await Self.held(flasher, deckBridge)
        #expect(updater.updating)
        #expect(updater.canCancel)
        updater.cancelUpdate()
        await run.value
        #expect(flasher.sawCancel)
        #expect(updater.screen.update == "Canceled. The panel was restarted.")
        #expect(deckBridge.posted == [.release, .done])
        #expect(!updater.updating)
    }

    @Test("Once writing has begun there's no cancel: it says why, a cancel asked for does nothing, and the write ends")
    func noCancelWhileWriting() async {
        let flasher = HeldFlasher(first: .writing(0))
        let (updater, run) = await Self.held(flasher)
        #expect(!updater.canCancel)
        #expect(updater.screen.cancelNote == "The panel can't be stopped while it's written: it has one app slot, so stopping now would leave it unable to start.")
        updater.cancelUpdate()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!flasher.sawCancel)
        flasher.finish()
        await run.value
        #expect(updater.screen.update == "Updated: the panel now runs build 2b7e9c1")
        #expect(updater.screen.cancelNote == nil)
    }

    @Test("An update asked for while one runs doesn't start a second")
    func oneAtATime() async {
        let flasher = HeldFlasher(first: .writing(0))
        let (updater, run) = await Self.held(flasher)
        await updater.updatePanel()
        flasher.finish()
        await run.value
        #expect(flasher.started == 1)
    }

    @Test("No look while an update runs: the panel's reset is a USB change, and a look would open its port")
    func noLookDuringUpdate() async {
        let rig = Rig()
        let usb = SlowUSB()
        let finder = DeviceFinder(usb: usb, midi: rig.midi, serial: rig.serial, log: rig.log)
        let flasher = HeldFlasher(first: .writing(0))
        let (updater, run) = await Self.held(flasher, finder: finder)
        await updater.refresh()
        #expect(usb.reads == 0)
        flasher.finish()
        await run.value
        #expect(usb.reads == 1)   // the one look after the update
    }

    @Test("A panel that told its build: the update the catalog has for it is offered")
    func offered() async {
        let rig = Rig()
        UpdaterScreenTests.panel(rig, printing: ["deck panel: boot, build 1d0683f"])
        let flasher = StubFlasher([])
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, flasher: flasher)
        await updater.refresh()
        #expect(updater.screen.panelUpdate == PanelUpdateOffer(version: "1.3.0", note: nil))
        #expect(flasher.asked == [PanelBuild(sha: "1d0683f")])
    }

    @Test("Nothing to offer: up to date, the build not read, or no flasher")
    func notOffered() async {
        let rig = Rig()
        UpdaterScreenTests.panel(rig, printing: ["deck panel: boot, build 1d0683f"])
        let upToDate = StubFlasher([])
        upToDate.offered = nil
        let one = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, flasher: upToDate)
        await one.refresh()
        #expect(one.screen.panelUpdate == nil)

        let none = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() })
        await none.refresh()
        #expect(none.screen.panelUpdate == nil)

        let silent = Rig()
        UpdaterScreenTests.panel(silent, printing: ["deck panel: waiting"])
        let unread = StubFlasher([])
        let two = Updater(finder: silent.finder, changes: AsyncStream { $0.finish() }, flasher: unread)
        await two.refresh()
        #expect(two.screen.panelUpdate == nil)
        #expect(unread.asked.isEmpty)
    }

    @Test("A panel whose port is there but whose build can't be read: repair is offered with the catalog's version")
    func repairOffered() async {
        let rig = Rig()
        UpdaterScreenTests.panel(rig, printing: ["deck panel: waiting"])
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, flasher: StubFlasher([]))
        await updater.refresh()
        #expect(updater.screen.panelRepair == PanelUpdateOffer(version: "1.3.0", note: nil))
        #expect(updater.screen.panelUpdate == nil)
    }

    @Test("No repair when the build was read, when there's no image to write, or no flasher")
    func repairNotOffered() async {
        let told = Rig()
        UpdaterScreenTests.panel(told, printing: ["deck panel: boot, build 1d0683f"])
        let one = Updater(finder: told.finder, changes: AsyncStream { $0.finish() }, flasher: StubFlasher([]))
        await one.refresh()
        #expect(one.screen.panelRepair == nil)

        let silent = Rig()
        UpdaterScreenTests.panel(silent, printing: [])
        let empty = StubFlasher([])
        empty.repairable = nil
        let two = Updater(finder: silent.finder, changes: AsyncStream { $0.finish() }, flasher: empty)
        await two.refresh()
        #expect(two.screen.panelRepair == nil)

        let three = Updater(finder: silent.finder, changes: AsyncStream { $0.finish() })
        await three.refresh()
        #expect(three.screen.panelRepair == nil)
    }

    @Test("Repair writes the catalog's image the same way as an update, asking DeckBridge first")
    func repair() async {
        let deckBridge = StubDeckBridge(answers: true)
        let flasher = StubFlasher([.connecting, .writing(0), .restarting, Self.updated])
        let updater = Self.updater(deckBridge, flasher)
        await updater.repairPanel()
        #expect(flasher.started == 1)
        #expect(updater.screen.update == "Updated: the panel now runs build 2b7e9c1")
        #expect(deckBridge.posted == [.release, .done])
    }

    @Test("The repair's confirm says the panel may just run older firmware, what it writes, and that Wi-Fi is kept")
    func repairConfirm() {
        #expect(UpdaterScreen.repairConfirm(version: "1.3.0")
            == "This panel didn't tell its build: it may not be starting, or it may run older firmware. Repair writes 1.3.0 to it. Wi-Fi is kept.")
    }
}
