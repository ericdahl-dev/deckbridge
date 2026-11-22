import Foundation
@testable import ControllerBridgeCore
import Testing

/// MIDI sends leave the event loop (#552): on the unit, a hung LC6000 blocked a send for 5.1 s and with it everything
/// else, OSC from Syndicate included. Sends go through one serial queue, in order, and return at once.
@Suite("MIDI send queue")
struct MIDISendQueueTests {
    /// An output whose sends block until `release` is signaled, recording what got through in order.
    final class BlockingOutput: MIDIOutput, @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _sent: [String] = []
        var blocking = true
        var sent: [String] { lock.withLock { _sent } }
        func send(_ event: MIDIEvent) throws {
            if lock.withLock({ blocking }) { gate.wait() }
            lock.withLock { _sent.append("\(event)") }
        }
        func send(color: LEDColorMessage) throws {
            if lock.withLock({ blocking }) { gate.wait() }
            lock.withLock { _sent.append("color \(color.note)") }
        }
        func close() {}
        func release() {
            lock.withLock { blocking = false }
            for _ in 0..<64 { gate.signal() }
        }
    }

    @Test("A send returns at once while the output blocks; once it unblocks, everything goes out in order")
    func nonBlocking() throws {
        let inner = BlockingOutput()
        let queue = MIDISendQueue(label: "test")
        let output = queue.output(inner)
        let started = Date()
        for note in 0..<5 { try output.send(.noteOn(channel: 0, note: UInt8(note), velocity: 1)) }
        #expect(Date().timeIntervalSince(started) < 0.2)
        inner.release()
        queue.drain()
        #expect(inner.sent == (0..<5).map { "\(MIDIEvent.noteOn(channel: 0, note: UInt8($0), velocity: 1))" })
    }

    /// The rig's MIDI system, its outputs through a send queue over an output that blocks.
    final class BlockedMIDISystem: MIDISystem, @unchecked Sendable {
        let inner = Rig.FakeMIDISystem(sources: [Rig.lc6000], destinations: [Rig.lc6000Out])
        let queue = MIDISendQueue(label: "test")
        let blocking = BlockingOutput()
        var sources: [MIDIEndpoint] { inner.sources }
        var destinations: [MIDIEndpoint] { inner.destinations }
        func connect(source: MIDIEndpoint) throws { try inner.connect(source: source) }
        func disconnect(source: MIDIEndpoint) { inner.disconnect(source: source) }
        func openOutput(destination: MIDIEndpoint) throws -> any MIDIOutput { queue.output(blocking) }
    }

    @Test("While the controller's port blocks, Syndicate's feedback is still handled at once; the LEDs follow once it unblocks")
    func feedbackWhileBlocked() throws {
        let midi = BlockedMIDISystem()
        let osc = Rig.FakeOSC()
        let coordinator = Coordinator(mapping: try Mapping.bundledDefault(), midi: midi, osc: osc, clock: Rig.FakeClock(),
                                      log: Rig.FakeLog())
        let started = Date()
        coordinator.start()                                       // paints every LED: all of it waits on the port
        coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)   // Play
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(osc.sent.contains(OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])))
        midi.blocking.release()
        midi.queue.drain()
        #expect(midi.blocking.sent.last { $0.contains("note: 1,") } == "\(MIDIEvent.noteOn(channel: 0, note: 1, velocity: 127))")
    }

    @Test("A port whose send hasn't returned within the bound is stuck: later sends to it are dropped, and said once")
    func stuck() throws {
        let inner = BlockingOutput()
        final class Notices: @unchecked Sendable {
            let lock = NSLock()
            var names: [String] = []
        }
        let notices = Notices()
        let queue = MIDISendQueue(label: "test", stuckAfter: 0.05) { name in notices.lock.withLock { notices.names.append(name) } }
        let output = queue.output(inner, name: "LC6000")
        try output.send(.noteOn(channel: 0, note: 1, velocity: 1))   // in flight, blocked
        Thread.sleep(forTimeInterval: 0.1)
        for note in 2...5 { try output.send(.noteOn(channel: 0, note: UInt8(note), velocity: 1)) }
        #expect(notices.lock.withLock { notices.names } == ["LC6000"])
        inner.release()
        queue.drain()
        #expect(inner.sent.count == 1)   // only the one in flight; the rest were dropped
    }

    @Test("A stuck port that sends again is no longer stuck: a reopened output starts fresh")
    func recovers() throws {
        let queue = MIDISendQueue(label: "test", stuckAfter: 0.05) { _ in }
        let stuckOne = BlockingOutput()
        let first = queue.output(stuckOne, name: "LC6000")
        try first.send(.noteOn(channel: 0, note: 1, velocity: 1))
        Thread.sleep(forTimeInterval: 0.1)
        stuckOne.release()
        queue.drain()
        let fresh = BlockingOutput()
        fresh.release()
        let second = queue.output(fresh, name: "LC6000")
        try second.send(.noteOn(channel: 0, note: 2, velocity: 1))
        queue.drain()
        #expect(fresh.sent.count == 1)
    }

    @Test("The backlog is bounded: past it the oldest LED writes are dropped, never the newest")
    func bounded() throws {
        let inner = BlockingOutput()
        let queue = MIDISendQueue(label: "test", backlog: 4)
        let output = queue.output(inner)
        try output.send(.noteOn(channel: 0, note: 0, velocity: 1))   // in flight
        Thread.sleep(forTimeInterval: 0.02)
        for note in 1...10 { try output.send(.noteOn(channel: 0, note: UInt8(note), velocity: 1)) }
        inner.release()
        queue.drain()
        #expect(inner.sent == [0, 7, 8, 9, 10].map { "\(MIDIEvent.noteOn(channel: 0, note: UInt8($0), velocity: 1))" })
    }

    /// One log of what reached the unit, across its ports, in order.
    final class UnitLog: @unchecked Sendable {
        let lock = NSLock()
        var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
    }

    final class LoggingOutput: MIDIOutput, @unchecked Sendable {
        let log: UnitLog
        init(_ log: UnitLog) { self.log = log }
        func send(_ event: MIDIEvent) throws {
            if case .noteOn(_, let note, let velocity) = event { log.add("led \(note)=\(velocity)") }
        }
        func send(color: LEDColorMessage) throws { log.add("color \(color.note)") }
        func close() {}
    }

    final class LoggingJogPort: JogDisplayPort, @unchecked Sendable {
        let log: UnitLog
        init(_ log: UnitLog) { self.log = log }
        func sendController(_ bytes: [UInt8]) { log.add("controller \(bytes.count)") }
        func sendWD(_ bytes: [UInt8]) { log.add("wd \(bytes.count)") }
        func flush() { log.add("flush") }
    }

    @Test("Flushing the jog display's port waits for everything queued, LEDs too, then flushes the port under it (#600)")
    func flushWaits() throws {
        final class SlowOutput: MIDIOutput, @unchecked Sendable {
            let log: UnitLog
            init(_ log: UnitLog) { self.log = log }
            func send(_ event: MIDIEvent) throws {
                Thread.sleep(forTimeInterval: 0.02)
                if case .noteOn(_, let note, let velocity) = event { log.add("led \(note)=\(velocity)") }
            }
            func send(color: LEDColorMessage) throws {}
            func close() {}
        }
        let log = UnitLog()
        let queue = MIDISendQueue(label: "test")
        let leds = queue.output(SlowOutput(log), name: "LC6000")
        let jog = queue.jogDisplayPort(LoggingJogPort(log))
        for note in 0..<3 { try leds.send(.noteOn(channel: 0, note: UInt8(note), velocity: 0)) }   // the releases
        jog.sendWD([0xF0, 0xF7])
        jog.sendController([0xF0, 0x00, 0xF7])   // the goodbye
        jog.flush()
        #expect(log.lock.withLock { log.lines } == ["led 0=0", "led 1=0", "led 2=0", "wd 2", "controller 3", "flush"])
    }

    @Test("The jog display's ports go through the same queue: the ring's hold reaches the unit before the upload starts (#422)")
    func ringHoldBeforeUpload() throws {
        let log = UnitLog()
        let queue = MIDISendQueue(label: "test")
        let leds = queue.output(LoggingOutput(log), name: "LC6000")
        let jog = queue.jogDisplayPort(LoggingJogPort(log))
        try leds.send(.noteOn(channel: 0, note: 40, velocity: 0))   // the ring held dark
        jog.sendWD(Array(repeating: 0, count: 300))                  // the upload
        try leds.send(.noteOn(channel: 0, note: 1, velocity: 127))
        jog.sendController([0xF0, 0xF7])
        queue.drain()
        #expect(log.lines == ["led 40=0", "wd 300", "led 1=127", "controller 2"])
    }

    @Test("Past the backlog bound, the jog display's SysEx is never dropped: only LED writes are")
    func sysexKept() throws {
        let log = UnitLog()
        let blocking = BlockingOutput()
        let queue = MIDISendQueue(label: "test", backlog: 3)
        let leds = queue.output(blocking, name: "LC6000")
        let jog = queue.jogDisplayPort(LoggingJogPort(log))
        try leds.send(.noteOn(channel: 0, note: 0, velocity: 1))   // in flight
        Thread.sleep(forTimeInterval: 0.02)
        jog.sendWD([1])
        for note in 1...5 { try leds.send(.noteOn(channel: 0, note: UInt8(note), velocity: 1)) }
        jog.sendWD([2, 2])
        blocking.release()
        queue.drain()
        #expect(log.lines == ["wd 1", "wd 2"])
    }

    @Test("The queued MIDI system opens outputs through the queue, and passes everything else straight through")
    func queuedSystem() throws {
        let inner = Rig.FakeMIDISystem(sources: [Rig.lc6000], destinations: [Rig.lc6000Out])
        let queue = MIDISendQueue(label: "test")
        let system = QueuedMIDISystem(inner: inner, queue: queue)
        #expect(system.sources == [Rig.lc6000] && system.destinations == [Rig.lc6000Out])
        try system.connect(source: Rig.lc6000)
        #expect(inner.connected == [Rig.lc6000.id])
        let output = try system.openOutput(destination: Rig.lc6000Out)
        #expect(!(output is Rig.FakeOutput))
        try output.send(.noteOn(channel: 0, note: 1, velocity: 127))
        queue.drain()
        #expect(inner.outputs[Rig.lc6000Out.id]?.sent == [.noteOn(channel: 0, note: 1, velocity: 127)])
    }

    @Test("A stuck port whose send finally returns takes data again: the jog display's ports are never reopened")
    func unsticks() throws {
        let inner = BlockingOutput()
        let queue = MIDISendQueue(label: "test", stuckAfter: 0.05)
        let output = queue.output(inner, name: "LC6000")
        try output.send(.noteOn(channel: 0, note: 1, velocity: 1))
        Thread.sleep(forTimeInterval: 0.1)
        try output.send(.noteOn(channel: 0, note: 2, velocity: 1))   // dropped: stuck
        inner.release()
        queue.drain()
        try output.send(.noteOn(channel: 0, note: 3, velocity: 1))   // the port answered: goes out
        queue.drain()
        #expect(inner.sent.count == 2 && inner.sent.last == "\(MIDIEvent.noteOn(channel: 0, note: 3, velocity: 1))")
    }
}

/// A port that went stuck and came back without reconnecting (#552): the LED writes dropped meanwhile left the unit
/// stale, so the queue says so and the Coordinator repaints every light once.
@Suite("MIDI send queue recovery")
struct MIDISendQueueRecoveryTests {
    typealias Queue = MIDISendQueueTests

    @Test("When a stuck port's send returns, the queue says so once, with the port's name")
    func recovered() throws {
        let inner = Queue.BlockingOutput()
        final class Names: @unchecked Sendable {
            let lock = NSLock()
            var names: [String] = []
        }
        let names = Names()
        let queue = MIDISendQueue(label: "test", stuckAfter: 0.05, onRecovered: { name in
            names.lock.withLock { names.names.append(name) }
        })
        let output = queue.output(inner, name: "LC6000")
        try output.send(.noteOn(channel: 0, note: 1, velocity: 1))
        Thread.sleep(forTimeInterval: 0.1)
        try output.send(.noteOn(channel: 0, note: 2, velocity: 1))   // stuck
        inner.release()
        queue.drain()
        #expect(names.lock.withLock { names.names } == ["LC6000"])
    }

    /// The jog display's port whose send doesn't return: the WD port of a unit that stopped reading (#595).
    final class BlockingJogPort: JogDisplayPort, @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var blocking = true
        private var _sent: [String] = []
        var sent: [String] { lock.withLock { _sent } }
        func sendController(_ bytes: [UInt8]) { lock.withLock { _sent.append("controller \(bytes.count)") } }
        func sendWD(_ bytes: [UInt8]) {
            if lock.withLock({ blocking }) { gate.wait() }
            lock.withLock { _sent.append("wd \(bytes.count)") }
        }
        var isAttached: Bool { true }
        func release() {
            lock.withLock { blocking = false }
            for _ in 0..<64 { gate.signal() }
        }
    }

    @Test("A wedged WD port goes stuck: its backlog of SysEx is dropped, not flooded into the unit, and it's named both ways")
    func wedgedWD() throws {
        final class Names: @unchecked Sendable {
            let lock = NSLock()
            var said: [String] = []
        }
        let names = Names()
        let inner = BlockingJogPort()
        let queue = MIDISendQueue(label: "test", stuckAfter: 0.05,
                                  onStuck: { name in names.lock.withLock { names.said.append("stuck \(name)") } },
                                  onRecovered: { name in names.lock.withLock { names.said.append("back \(name)") } })
        let jog = queue.jogDisplayPort(inner)
        jog.sendWD([1])                                   // in flight, wedged
        Thread.sleep(forTimeInterval: 0.1)
        for _ in 0..<50 { jog.sendWD([2, 2]) }            // a second of 50/s needle steps: dropped
        inner.release()
        queue.drain()
        jog.sendController([0xF0, 0xF7])
        queue.drain()
        #expect(inner.sent == ["wd 1", "controller 2"])
        #expect(names.lock.withLock { names.said } == ["stuck jog display (WD)", "back jog display (WD)"])
    }

    @Test("A recovered port's name picks the command: the jog display's two ports restart the display, any other repaints")
    func commandForRecovery() {
        #expect(Coordinator.Command.afterRecovery(of: "jog display (WD)") == .jogDisplayRecovered)
        #expect(Coordinator.Command.afterRecovery(of: "jog display (Controller)") == .jogDisplayRecovered)
        #expect(Coordinator.Command.afterRecovery(of: "LC6000 PRIME Controller") == .portRecovered)
        #expect(Coordinator.Command.jogDisplayRecovered.routing == .real)
    }

    @Test("The Coordinator's port-recovered command repaints every light of the layer in front")
    func repaints() throws {
        let rig = try Rig()
        rig.coordinator.start()
        let painted = Set(rig.leds.keys)
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        rig.coordinator.apply(.portRecovered)
        #expect(Set(rig.leds.keys).isSuperset(of: painted))
    }
}
