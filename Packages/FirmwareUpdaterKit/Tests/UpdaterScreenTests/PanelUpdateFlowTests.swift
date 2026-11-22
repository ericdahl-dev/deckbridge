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

    func borrow() -> PortBorrow { PortBorrow(channel: self, sleep: { _ in }) }
}

/// The flasher (#687) as the updater sees it: it reports these steps, as PanelUpdate would.
final class StubFlasher: PanelFlashing, @unchecked Sendable {
    let steps: [PanelUpdate.Step]
    private let runs = Mutex(0)
    var started: Int { runs.withLock { $0 } }

    init(_ steps: [PanelUpdate.Step]) { self.steps = steps }

    func flash(report: @escaping @Sendable (PanelUpdate.Step) -> Void) async {
        runs.withLock { $0 += 1 }
        for step in steps { report(step) }
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
}
