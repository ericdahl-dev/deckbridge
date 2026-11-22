import Foundation
@testable import ControllerBridgeCore
import Testing

/// The engine's loop never asks CoreMIDI for its endpoints (#595): a hung unit can hold the MIDI server for seconds, and
/// every lookup on the loop waited with it. The lists are read on a change, off the loop, and the loop reads them.
@Suite("MIDI endpoint snapshot")
struct MIDISnapshotTests {
    /// A MIDI system whose endpoint lookups hang while `blocked`, as CoreMIDI's do behind a wedged unit. A lookup made
    /// while blocked is counted and gives up after `patience`, so a failing test fails instead of hanging.
    final class BlockingMIDISystem: MIDISystem, @unchecked Sendable {
        private let lock = NSLock()
        private var _sources: [MIDIEndpoint]
        private var _destinations: [MIDIEndpoint]
        private var blocked = false
        private(set) var waited = 0
        var connected: [MIDIEndpoint.ID] = []
        let patience = 0.3

        init(sources: [MIDIEndpoint], destinations: [MIDIEndpoint]) {
            _sources = sources
            _destinations = destinations
        }

        func set(sources: [MIDIEndpoint], destinations: [MIDIEndpoint]) {
            lock.withLock { _sources = sources; _destinations = destinations }
        }
        func block(_ on: Bool) { lock.withLock { blocked = on } }

        private func lookup<T>(_ read: () -> T) -> T {
            if lock.withLock({ blocked }) {
                lock.withLock { waited += 1 }
                Thread.sleep(forTimeInterval: patience)
            }
            return lock.withLock(read)
        }

        var sources: [MIDIEndpoint] { lookup { _sources } }
        var destinations: [MIDIEndpoint] { lookup { _destinations } }
        func connect(source: MIDIEndpoint) throws { connected.append(source.id) }
        func disconnect(source: MIDIEndpoint) { connected.removeAll { $0 == source.id } }
        func openOutput(destination: MIDIEndpoint) throws -> any MIDIOutput { Rig.FakeOutput() }
    }

    static let unit = MIDIEndpoint(id: 1, name: "LC6000 PRIME Controller")
    static let wd = MIDIEndpoint(id: 2, name: "LC6000 PRIME WD")

    @Test("While the MIDI server hangs, the loop's read of sources and destinations returns at once, with the last lists")
    func readsDontWait() {
        let inner = BlockingMIDISystem(sources: [Self.unit], destinations: [Self.unit])
        let system = SnapshotMIDISystem(inner: inner)
        inner.block(true)
        #expect(system.sources == [Self.unit])
        #expect(system.destinations == [Self.unit])
        #expect(inner.waited == 0)
    }

    @Test("A refresh, made off the loop on a change, gives the loop the new lists")
    func refreshes() {
        let inner = BlockingMIDISystem(sources: [Self.unit], destinations: [])
        let system = SnapshotMIDISystem(inner: inner)
        inner.set(sources: [Self.unit, Self.wd], destinations: [Self.wd])
        #expect(system.sources == [Self.unit])
        system.refresh()
        #expect(system.sources == [Self.unit, Self.wd])
        #expect(system.destinations == [Self.wd])
    }

    @Test("Connecting, disconnecting and opening go straight to the system")
    func passesThrough() throws {
        let inner = BlockingMIDISystem(sources: [Self.unit], destinations: [Self.unit])
        let system = SnapshotMIDISystem(inner: inner)
        try system.connect(source: Self.unit)
        #expect(inner.connected == [Self.unit.id])
        system.disconnect(source: Self.unit)
        #expect(inner.connected.isEmpty)
        _ = try system.openOutput(destination: Self.unit)
    }

    /// The jog display's port, whose lookup of the WD port hangs while `blocked`.
    final class BlockingJogPort: JogDisplayPort, @unchecked Sendable {
        private let lock = NSLock()
        private var attached: Bool
        private var blocked = false
        private(set) var waited = 0
        var wd: [[UInt8]] = []
        private(set) var flushed = 0
        func flush() { flushed += 1 }
        init(attached: Bool) { self.attached = attached }
        func set(attached: Bool) { lock.withLock { self.attached = attached } }
        func block(_ on: Bool) { lock.withLock { blocked = on } }
        func sendController(_ bytes: [UInt8]) {}
        func sendWD(_ bytes: [UInt8]) { wd.append(bytes) }
        var isAttached: Bool {
            if lock.withLock({ blocked }) {
                lock.withLock { waited += 1 }
                Thread.sleep(forTimeInterval: 0.3)
            }
            return lock.withLock { attached }
        }
    }

    @Test("The jog display's attached check, made every tick, answers from the snapshot while the MIDI server hangs")
    func attachedDoesntWait() {
        let inner = BlockingJogPort(attached: true)
        let port = SnapshotJogDisplayPort(inner: inner)
        inner.block(true)
        #expect(port.isAttached)
        #expect(inner.waited == 0)
        inner.block(false)
        inner.set(attached: false)
        #expect(port.isAttached, "until the next refresh")
        port.refresh()
        #expect(!port.isAttached)
        port.sendWD([1, 2])
        #expect(inner.wd == [[1, 2]])
    }

    @Test("Quitting flushes through the snapshot to the port under it (#600)")
    func flushPassesThrough() {
        let inner = BlockingJogPort(attached: true)
        let port = SnapshotJogDisplayPort(inner: inner)
        port.flush()
        #expect(inner.flushed == 1)
    }
}
