// The engine's loop never asks CoreMIDI for its endpoints (#595). On the unit, a hung LC6000 held the MIDI server for
// seconds (#428), and every lookup the loop made waited with it: the whole trace, OSC included, went silent. The lists
// are read when CoreMIDI's setup changes, off the loop and off the main thread, before the Coordinator hears of the
// change; the loop reads what was last read.
import Foundation

/// A MIDI system whose sources and destinations are the lists last read by `refresh()`. Connecting, disconnecting and
/// opening go straight to the inner system.
public final class SnapshotMIDISystem: MIDISystem, @unchecked Sendable {
    private let inner: any MIDISystem
    private let lock = NSLock()
    private var lists: (sources: [MIDIEndpoint], destinations: [MIDIEndpoint])

    /// Reads the lists once now: build it where waiting is fine (at start, not on the loop).
    public init(inner: any MIDISystem) {
        self.inner = inner
        lists = (inner.sources, inner.destinations)
    }

    /// Reads the lists again. Call it off the loop when CoreMIDI's setup changes, before the Coordinator hears of it.
    public func refresh() {
        let fresh = (inner.sources, inner.destinations)
        lock.withLock { lists = fresh }
    }

    public var sources: [MIDIEndpoint] { lock.withLock { lists.sources } }
    public var destinations: [MIDIEndpoint] { lock.withLock { lists.destinations } }
    public func connect(source: MIDIEndpoint) throws { try inner.connect(source: source) }
    public func disconnect(source: MIDIEndpoint) { inner.disconnect(source: source) }
    public func openOutput(destination: MIDIEndpoint) throws -> any MIDIOutput {
        try inner.openOutput(destination: destination)
    }
}

/// The jog display's port, its `isAttached` (asked every tick) the answer last read by `refresh()`. Sends go straight
/// through.
public final class SnapshotJogDisplayPort: JogDisplayPort, @unchecked Sendable {
    private let inner: any JogDisplayPort
    private let lock = NSLock()
    private var attached: Bool

    /// Asks once now: build it where waiting is fine.
    public init(inner: any JogDisplayPort) {
        self.inner = inner
        attached = inner.isAttached
    }

    /// Asks again. Call it off the loop when CoreMIDI's setup changes, before the Coordinator hears of it.
    public func refresh() {
        let now = inner.isAttached
        lock.withLock { attached = now }
    }

    public var isAttached: Bool { lock.withLock { attached } }
    public func sendController(_ bytes: [UInt8]) { inner.sendController(bytes) }
    public func sendWD(_ bytes: [UInt8]) { inner.sendWD(bytes) }
    public func flush() { inner.flush() }
}
