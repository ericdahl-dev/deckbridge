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
    private let runs = Mutex(0)
    var started: Int { runs.withLock { $0 } }

    init(_ steps: [PanelUpdate.Step]) { self.steps = steps }

    func flash(report: @escaping @Sendable (PanelUpdate.Step) -> Void) async {
        runs.withLock { $0 += 1 }
        for step in steps { report(step) }
    }
}

/// A flasher that writes until it is canceled, then says so as PanelUpdate does.
final class WaitingFlasher: PanelFlashing, @unchecked Sendable {
    func offer(for build: PanelBuild) -> PanelUpdateOffer? { nil }
    private let state = Mutex((runs: 0, writing: false))
    var started: Int { state.withLock { $0.runs } }
    var writing: Bool { state.withLock { $0.writing } }

    func flash(report: @escaping @Sendable (PanelUpdate.Step) -> Void) async {
        state.withLock { $0.runs += 1 }
        report(.writing(0.1))
        state.withLock { $0.writing = true }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        report(.failed(.canceled))
    }
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

    @Test("A failure: its text shows, the port still goes back once, and the next update can start")
    func failure() async {
        let deckBridge = StubDeckBridge(answers: true)
        let flasher = StubFlasher([.connecting, .failed(.verifyFailed(address: 0x10000))])
        let updater = Self.updater(deckBridge, flasher)
        await updater.updatePanel()
        #expect(updater.screen.update == "The written firmware didn't check out. The panel may not start: try again before unplugging it.")
        #expect(deckBridge.posted == [.release, .done])
        await updater.updatePanel()
        #expect(flasher.started == 2)
    }

    @Test("Cancel while writing: the flasher is stopped, says so, and the port goes back")
    func cancel() async {
        let deckBridge = StubDeckBridge(answers: true)
        let flasher = WaitingFlasher()
        let waiting = Updater(finder: Rig().finder, changes: AsyncStream { $0.finish() }, borrow: deckBridge.borrow,
                              flasher: flasher)
        let run = Task { await waiting.updatePanel() }
        while !flasher.writing { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(waiting.updating)
        waiting.cancelUpdate()
        await run.value
        #expect(waiting.screen.update == "Canceled. The panel was restarted.")
        #expect(deckBridge.posted == [.release, .done])
        #expect(!waiting.updating)
    }

    @Test("An update asked for while one runs doesn't start a second")
    func oneAtATime() async {
        let flasher = WaitingFlasher()
        let only = Updater(finder: Rig().finder, changes: AsyncStream { $0.finish() },
                           borrow: StubDeckBridge(answers: true).borrow, flasher: flasher)
        let run = Task { await only.updatePanel() }
        while !flasher.writing { try? await Task.sleep(for: .milliseconds(5)) }
        await only.updatePanel()
        only.cancelUpdate()
        await run.value
        #expect(flasher.started == 1)
    }

    @Test("No look while an update runs: the panel's reset is a USB change, and a look would open its port")
    func noLookDuringUpdate() async {
        let rig = Rig()
        let usb = SlowUSB()
        let finder = DeviceFinder(usb: usb, midi: rig.midi, serial: rig.serial, log: rig.log)
        let flasher = WaitingFlasher()
        let updater = Updater(finder: finder, changes: AsyncStream { $0.finish() },
                              borrow: StubDeckBridge(answers: true).borrow, flasher: flasher)
        let run = Task { await updater.updatePanel() }
        while !flasher.writing { try? await Task.sleep(for: .milliseconds(5)) }
        await updater.refresh()
        #expect(usb.reads == 0)
        updater.cancelUpdate()
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
}
