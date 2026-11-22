import Foundation
@testable import ControllerBridgeCore
import Testing

/// The display feed's queue (#616): the Coordinator's sends are handed to a worker, never sent on the event path, and
/// dropped, not queued, once the worker is a backlog behind. A manual worker stands in for the app's serial queue.
@Suite("Display feed: the queue")
struct DisplayFeedQueueTests {
    final class Worker: @unchecked Sendable {
        var jobs: [@Sendable () -> Void] = []
        func runAll() {
            let now = jobs
            jobs.removeAll()
            for job in now { job() }
        }
    }

    static func message(_ n: Int) -> OSCMessage { OSCMessage("/DeckBridge/Display/deck", [.int(Int32(n))]) }

    @Test("A send goes out on the worker, not on the caller")
    func offTheCaller() {
        let inner = Rig.FakeOSC(), worker = Worker()
        let queue = DisplayFeedQueue(inner, backlog: 4) { worker.jobs.append($0) }
        queue.send(Self.message(1))
        #expect(inner.sent == [])
        worker.runAll()
        #expect(inner.sent == [Self.message(1)])
    }

    @Test("Behind by the backlog, later sends are dropped and counted; once the worker catches up, sends go again")
    func dropsWhenBehind() {
        let inner = Rig.FakeOSC(), worker = Worker()
        let queue = DisplayFeedQueue(inner, backlog: 4) { worker.jobs.append($0) }
        for n in 1...6 { queue.send(Self.message(n)) }
        #expect(worker.jobs.count == 4)
        #expect(queue.dropped == 2)
        worker.runAll()
        #expect(inner.sent == (1...4).map(Self.message))
        queue.send(Self.message(7))
        worker.runAll()
        #expect(inner.sent.last == Self.message(7))
    }

    @Test("In the trace: one line when it starts dropping, one when it has caught up, with how many it dropped (#636)")
    func dropsTraced() {
        let inner = Rig.FakeOSC(), worker = Worker()
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let queue = DisplayFeedQueue(inner, backlog: 2) { worker.jobs.append($0) }
        queue.trace = { category, text in if category == .displayFeed { lines.all.append(text) } }
        for n in 1...5 { queue.send(Self.message(n)) }
        #expect(lines.all == ["dropping sends: 2 waiting on the network"])
        worker.runAll()
        queue.send(Self.message(6))
        #expect(lines.all == ["dropping sends: 2 waiting on the network", "sending again after 3 dropped"])
    }

    @Test("A bundle is one job and one place in the backlog, sent as a bundle, and dropped whole (#636)")
    func bundles() {
        final class Bundles: OSCSender, @unchecked Sendable {
            var bundles: [[OSCMessage]] = []
            func send(_ message: OSCMessage) { bundles.append([message]) }
            func send(bundle messages: [OSCMessage]) { bundles.append(messages) }
        }
        let inner = Bundles(), worker = Worker()
        let queue = DisplayFeedQueue(inner, backlog: 2) { worker.jobs.append($0) }
        let two = [Self.message(1), Self.message(2)]
        queue.send(bundle: two)
        queue.send(bundle: [Self.message(3)])
        queue.send(bundle: [Self.message(4), Self.message(5)])
        #expect(worker.jobs.count == 2)
        #expect(queue.dropped == 1)
        worker.runAll()
        #expect(inner.bundles == [two, [Self.message(3)]])
    }
}
