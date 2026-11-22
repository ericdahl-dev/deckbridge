import DeviceFinder
import FirmwareModel
import Foundation
import PortHandoff
import Testing
import UpdaterScreen

/// A busy panel port (#710's follow-up): DeckBridge holds it for the cable feed, so the updater asks DeckBridge for it,
/// looks, and gives it back. With no answer it forces nothing and says how to free it.
@Suite("Updater: borrowing a busy panel port from DeckBridge")
@MainActor
struct BusyPortBorrowTests {
    typealias Screen = UpdaterScreenTests

    /// DeckBridge on the other end: when it answers, "release" frees the port and "done" takes it again.
    final class DeckBridge: HandoffChannel, @unchecked Sendable {
        let serial: FakeSerial
        var answers: Bool
        /// Another app (a serial monitor) holds the port too: DeckBridge letting go doesn't free it.
        var alsoHeld = false
        private let lock = NSLock()
        private var listeners: [AsyncStream<HandoffSignal>.Continuation] = []
        private var _posted: [HandoffSignal] = []
        var posted: [HandoffSignal] { lock.withLock { _posted } }

        init(serial: FakeSerial, answers: Bool) {
            self.serial = serial
            self.answers = answers
        }

        func listen() -> AsyncStream<HandoffSignal> {
            let (stream, continuation) = AsyncStream<HandoffSignal>.makeStream()
            lock.withLock { listeners.append(continuation) }
            return stream
        }

        func post(_ signal: HandoffSignal) {
            lock.withLock { _posted.append(signal) }
            guard answers else { return }
            switch signal {
            case .release:
                if !alsoHeld { serial.busy = [] }
                for listener in lock.withLock({ listeners }) { listener.yield(.released) }
            case .done: serial.busy = [Screen.port]
            case .released: break
            }
        }
    }

    /// A running panel whose port DeckBridge holds, and an updater that may borrow it.
    static func updater(answers: Bool) -> (Updater, Rig, DeckBridge) {
        let rig = Rig()
        Screen.panel(rig, printing: [])
        rig.serial.answers[Screen.port] = ["deck panel: build 1d0683f, version 1.2.0"]
        rig.serial.busy = [Screen.port]
        let deckBridge = DeckBridge(serial: rig.serial, answers: answers)
        let borrow: @Sendable () -> PortBorrow = { PortBorrow(channel: deckBridge) { _ in for _ in 0..<50 { await Task.yield() } } }
        let updater = Updater(finder: rig.finder, changes: AsyncStream { $0.finish() }, log: rig.log, borrow: borrow)
        return (updater, rig, deckBridge)
    }

    @Test("DeckBridge lets go: the updater reads the panel's version, then gives the port back")
    func borrowedAndGivenBack() async {
        let (updater, _, deckBridge) = Self.updater(answers: true)
        await updater.refresh()
        #expect(updater.screen.panel.detail == "Version 1.2.0, build 1d0683f")
        #expect(deckBridge.posted == [.release, .done])
    }

    @Test("No answer from DeckBridge: the port isn't forced, and the screen says to turn off the switch or quit DeckBridge")
    func noAnswer() async {
        let (updater, rig, deckBridge) = Self.updater(answers: false)
        await updater.refresh()
        #expect(updater.screen.panel.detail == UpdaterScreen.deckBridgeNoAnswer)
        #expect(deckBridge.posted == [.release])
        #expect(rig.serial.writes.isEmpty)
    }

    @Test("Look again asks again: once DeckBridge answers, the port is borrowed and the no-answer line goes")
    func lookAgainAsksAgain() async {
        let (updater, _, deckBridge) = Self.updater(answers: false)
        await updater.refresh()
        deckBridge.answers = true
        await updater.refresh()
        #expect(updater.screen.panel.detail == "Version 1.2.0, build 1d0683f")
        #expect(deckBridge.posted == [.release, .release, .done])
    }

    @Test("DeckBridge lets go but another app still holds the port: the busy line, not the no-answer one from before")
    func stillHeldByAnotherApp() async {
        let (updater, _, deckBridge) = Self.updater(answers: false)
        await updater.refresh()
        deckBridge.answers = true
        deckBridge.alsoHeld = true
        await updater.refresh()
        #expect(updater.screen.panel.detail == UpdaterScreen.portBusy)
        #expect(deckBridge.posted == [.release, .release, .done])
    }

    @Test("The log says DeckBridge let go, then that the port went back (#710's owner run had neither)")
    func logsLentAndGivenBack() async {
        let (updater, rig, _) = Self.updater(answers: true)
        await updater.refresh()
        let asked = rig.log.lines.firstIndex(of: "deck panel: asked DeckBridge for the port, it let go")
        let back = rig.log.lines.firstIndex(of: "deck panel: gave the port back to DeckBridge")
        #expect(asked != nil && back != nil && asked! < back!)
    }

    @Test("The log says DeckBridge didn't answer, and nothing about giving back")
    func logsNoAnswer() async {
        let (updater, rig, _) = Self.updater(answers: false)
        await updater.refresh()
        #expect(rig.log.lines.contains("deck panel: asked DeckBridge for the port, no answer in 3 s"))
        #expect(!rig.log.lines.contains("deck panel: gave the port back to DeckBridge"))
    }
}
