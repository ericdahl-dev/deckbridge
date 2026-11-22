// MIDI sends off the event loop (#552). On the unit (#428), a hung LC6000 blocked a CoreMIDI send for 5.1 s, and with it
// the one task that runs everything: OSC from Syndicate, ticks, the trace. Sends now go through one serial queue, so
// the loop never waits on a port. One queue for every port keeps their order: the ring's hold goes out before a jog
// display upload starts (#422), on another port.
//
// A port whose send hasn't returned within `stuckAfter` is stuck: later sends to it are dropped, and `onStuck` says so
// once, until that send returns or the port is opened again (a reconnect, #429, which repaints). The backlog is bounded: past it the oldest
// LED write is dropped (a light's state; the latest is what matters), never anything else.
import Foundation

public final class MIDISendQueue: @unchecked Sendable {
    private struct Item {
        let port: Int
        /// An LED write: state, so an old one may be dropped.
        let droppable: Bool
        let work: @Sendable () -> Void
    }

    private let worker: DispatchQueue
    private let lock = NSLock()
    private let stuckAfter: Double
    private let backlog: Int
    private let onStuck: @Sendable (String) -> Void
    private let onRecovered: @Sendable (String) -> Void
    private var names: [Int: String] = [:]
    private var items: [Item] = []
    private var running = false
    private var inFlight: (port: Int, since: Double)?
    private var stuck: Set<Int> = []
    private var nextPort = 0

    /// `onStuck` gets the port's name, once, when it goes stuck; `onRecovered`, when its send returns after that, so
    /// what was dropped meanwhile can be sent again.
    public init(label: String, stuckAfter: Double = 0.5, backlog: Int = 512,
                onStuck: @escaping @Sendable (String) -> Void = { _ in },
                onRecovered: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onRecovered = onRecovered
        worker = DispatchQueue(label: label)
        self.stuckAfter = stuckAfter
        self.backlog = backlog
        self.onStuck = onStuck
    }

    /// `inner`, its sends made on this queue, in the order they were asked for. Each call is a new port: one reopened
    /// after a reconnect starts out not stuck.
    public func output(_ inner: any MIDIOutput, name: String = "") -> any MIDIOutput {
        QueuedMIDIOutput(inner: inner, queue: self, port: newPort(), name: name)
    }

    func newPort() -> Int { lock.withLock { nextPort += 1; return nextPort } }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Queues `work` for `port`, unless the port is stuck. Returns at once.
    func enqueue(port: Int, name: String, droppable: Bool, _ work: @escaping @Sendable () -> Void) {
        var newlyStuck = false
        let start: Bool = lock.withLock {
            if stuck.contains(port) { return false }
            if let flight = inFlight, flight.port == port, Self.now - flight.since >= stuckAfter {
                stuck.insert(port)
                names[port] = name
                newlyStuck = true
                items.removeAll { $0.port == port }
                return false
            }
            items.append(Item(port: port, droppable: droppable, work: work))
            if items.count > backlog, let oldest = items.firstIndex(where: \.droppable) { items.remove(at: oldest) }
            guard !running else { return false }
            running = true
            return true
        }
        if newlyStuck { onStuck(name) }
        if start { worker.async { self.run() } }
    }

    private func run() {
        while true {
            let next: Item? = lock.withLock {
                guard !items.isEmpty else {
                    running = false
                    inFlight = nil
                    return nil
                }
                let item = items.removeFirst()
                inFlight = (item.port, Self.now)
                return item
            }
            guard let next else { return }
            next.work()
            // The send returned: the port takes data again (the jog display's ports are never reopened).
            let recovered: String? = lock.withLock { stuck.remove(next.port) != nil ? names[next.port] ?? "" : nil }
            if let recovered { onRecovered(recovered) }
        }
    }

    /// Waits until everything queued so far has gone. For tests and for closing.
    public func drain() {
        while lock.withLock({ running || !items.isEmpty }) { worker.sync {} }
    }
}

/// An output whose sends return at once. A send that fails on the queue (the destination is gone) makes the next send
/// here throw, which the Coordinator treats as an unplug, as it did a failed send before.
final class QueuedMIDIOutput: MIDIOutput, @unchecked Sendable {
    private let inner: any MIDIOutput
    private let queue: MIDISendQueue
    private let port: Int
    private let name: String
    private let lock = NSLock()
    private var failure: (any Error)?

    init(inner: any MIDIOutput, queue: MIDISendQueue, port: Int, name: String) {
        self.inner = inner
        self.queue = queue
        self.port = port
        self.name = name
    }

    func send(_ event: MIDIEvent) throws {
        try enqueue { try $0.send(event) }
    }

    func send(color: LEDColorMessage) throws {
        try enqueue { try $0.send(color: color) }
    }

    func close() {
        let inner = self.inner
        queue.enqueue(port: port, name: name, droppable: false) { inner.close() }
    }

    /// Every send here is an LED's: a note-on, a CC (a meter) or a color message.
    private func enqueue(_ send: @escaping @Sendable (any MIDIOutput) throws -> Void) throws {
        if let failure = lock.withLock({ self.failure }) { throw failure }
        let inner = self.inner
        queue.enqueue(port: port, name: name, droppable: true) { [weak self] in
            do { try send(inner) } catch { self?.lock.withLock { self?.failure = error } }
        }
    }
}

extension MIDISendQueue {
    /// The names the jog display's two ports go by in `onStuck` and `onRecovered`.
    public static let jogControllerName = "jog display (Controller)"
    public static let jogWDName = "jog display (WD)"
    public static let jogDisplayPortNames: Set<String> = [jogControllerName, jogWDName]

    /// The jog display's two ports (#165), their sends on this queue too: in order with the LEDs, so the ring's hold
    /// reaches the unit before an upload starts (#422). Their SysEx is never dropped for the backlog; a stuck port's
    /// is, until the port is opened again.
    public func jogDisplayPort(_ inner: any JogDisplayPort) -> any JogDisplayPort {
        QueuedJogDisplayPort(inner: inner, queue: self, controller: newPort(), wd: newPort())
    }
}

final class QueuedJogDisplayPort: JogDisplayPort, @unchecked Sendable {
    private let inner: any JogDisplayPort
    private let queue: MIDISendQueue
    private let controller: Int
    private let wd: Int

    init(inner: any JogDisplayPort, queue: MIDISendQueue, controller: Int, wd: Int) {
        self.inner = inner
        self.queue = queue
        self.controller = controller
        self.wd = wd
    }

    func sendController(_ bytes: [UInt8]) {
        let inner = self.inner
        queue.enqueue(port: controller, name: MIDISendQueue.jogControllerName, droppable: false) { inner.sendController(bytes) }
    }

    func sendWD(_ bytes: [UInt8]) {
        let inner = self.inner
        queue.enqueue(port: wd, name: MIDISendQueue.jogWDName, droppable: false) { inner.sendWD(bytes) }
    }

    var isAttached: Bool { inner.isAttached }

    /// Quitting (#600): everything queued so far, on every port (the releases too), then the port under it.
    func flush() {
        queue.drain()
        inner.flush()
    }
}

/// A MIDI system whose outputs send through a `MIDISendQueue` (#552); everything else is the inner system's.
public final class QueuedMIDISystem: MIDISystem, @unchecked Sendable {
    private let inner: any MIDISystem
    private let queue: MIDISendQueue

    public init(inner: any MIDISystem, queue: MIDISendQueue) {
        self.inner = inner
        self.queue = queue
    }

    public var sources: [MIDIEndpoint] { inner.sources }
    public var destinations: [MIDIEndpoint] { inner.destinations }
    public func connect(source: MIDIEndpoint) throws { try inner.connect(source: source) }
    public func disconnect(source: MIDIEndpoint) { inner.disconnect(source: source) }

    public func openOutput(destination: MIDIEndpoint) throws -> any MIDIOutput {
        queue.output(try inner.openOutput(destination: destination), name: destination.name)
    }
}
