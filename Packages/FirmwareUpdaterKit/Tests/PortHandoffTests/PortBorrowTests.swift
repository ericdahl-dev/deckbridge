import PortHandoff
import Testing
import Synchronization

/// Borrowing the deck panel's USB port from DeckBridge (#710), on a fake channel and clock: ask, wait for "released",
/// give it back with "done". With no answer the updater forces nothing: it says what to do instead.
@Suite("Updater: borrowing the panel's port from DeckBridge")
struct PortBorrowTests {
    /// The two apps' signals, as DeckBridge posts and hears them: its ControllerBridgeKit has the same names.
    @Test("The signals' names, the same in both apps")
    func names() {
        #expect(HandoffSignal.release.name == "dev.ericdahl.deckbridge.panel-port.release")
        #expect(HandoffSignal.released.name == "dev.ericdahl.deckbridge.panel-port.released")
        #expect(HandoffSignal.done.name == "dev.ericdahl.deckbridge.panel-port.done")
    }

    @Test("DeckBridge answers: lent, after asking once; giving it back says done, once")
    func answered() async {
        let channel = FakeChannel(answer: true)
        let borrow = PortBorrow(channel: channel, sleep: FakeSleep().sleep)
        #expect(await borrow.borrow() == .lent)
        #expect(channel.posted == [.release])
        borrow.giveBack()
        borrow.giveBack()
        #expect(channel.posted == [.release, .done])
    }

    @Test("No answer in 3 s (an old DeckBridge, or hung): no answer, and giving back posts nothing")
    func noAnswer() async {
        let channel = FakeChannel(answer: false)
        let sleep = FakeSleep()
        let borrow = PortBorrow(channel: channel, sleep: sleep.sleep)
        #expect(await borrow.borrow() == .noAnswer)
        #expect(sleep.asked == [3])
        borrow.giveBack()
        #expect(channel.posted == [.release])
    }

    @Test("Only DeckBridge's released counts: another signal heard isn't an answer")
    func otherSignals() async {
        let channel = FakeChannel(answer: false, alsoHeard: [.release, .done])
        let borrow = PortBorrow(channel: channel, sleep: FakeSleep().sleep)
        #expect(await borrow.borrow() == .noAnswer)
    }
}

/// DeckBridge on the other end: answers "released" to "release" when `answer`, after `alsoHeard`.
final class FakeChannel: HandoffChannel, @unchecked Sendable {
    let answer: Bool
    let alsoHeard: [HandoffSignal]
    private let lock = Mutex<[HandoffSignal]>([])
    private var listeners: [AsyncStream<HandoffSignal>.Continuation] = []
    var posted: [HandoffSignal] { lock.withLock { $0 } }

    init(answer: Bool, alsoHeard: [HandoffSignal] = []) {
        self.answer = answer
        self.alsoHeard = alsoHeard
    }

    func listen() -> AsyncStream<HandoffSignal> {
        let (stream, continuation) = AsyncStream<HandoffSignal>.makeStream()
        listeners.append(continuation)
        return stream
    }

    func post(_ signal: HandoffSignal) {
        lock.withLock { $0.append(signal) }
        guard signal == .release else { return }
        for listener in listeners {
            for other in alsoHeard { listener.yield(other) }
            if answer { listener.yield(.released) }
        }
    }
}

/// A clock whose sleeps end at once, recording how long each was.
final class FakeSleep: @unchecked Sendable {
    private let lock = Mutex<[Double]>([])
    var asked: [Double] { lock.withLock { $0 } }
    var sleep: @Sendable (Double) async -> Void {
        { [self] seconds in
            lock.withLock { $0.append(seconds) }
            // Let an answer already queued win: the real wait is 3 s, an answer comes in milliseconds.
            for _ in 0..<50 { await Task.yield() }
        }
    }
}
