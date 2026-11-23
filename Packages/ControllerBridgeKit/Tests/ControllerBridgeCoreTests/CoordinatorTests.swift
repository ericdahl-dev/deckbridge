import Foundation
import ControllerBridgeCore
import Testing

/// A fake LC6000 plus a fake Syndicate, plugged into a Coordinator. Tests check only what comes out: the OSC sent
/// to Syndicate, the LED messages sent to the controller, and the log.
final class Rig {
    final class FakeOutput: MIDIOutput, @unchecked Sendable {
        struct SendFailed: Error {}
        var sent: [MIDIEvent] = []
        var closed = false
        /// Set to make every send fail, as a pulled cable can.
        var failing = false
        func send(_ event: MIDIEvent) throws {
            if failing { throw SendFailed() }
            sent.append(event)
            writes.append(.event(event))
        }
        /// Denon's color messages (#530), in order, apart from the channel messages.
        var colors: [LEDColorMessage] = []
        func send(color: LEDColorMessage) throws {
            if failing { throw SendFailed() }
            colors.append(color)
            writes.append(.color(color))
        }
        /// Everything sent, both kinds in one order (#530): on the unit, a note-on and a color message for the same LED
        /// each replace the other, so the last one is what shows.
        enum Write: Equatable { case event(MIDIEvent), color(LEDColorMessage) }
        var writes: [Write] = []
        func close() { closed = true }
    }

    final class FakeMIDISystem: MIDISystem, @unchecked Sendable {
        var sources: [MIDIEndpoint]
        var destinations: [MIDIEndpoint]
        var connected: [MIDIEndpoint.ID] = []
        /// Every source ever connected, in order, even if disconnected since: proves a device was never touched (#105).
        var everConnected: [MIDIEndpoint.ID] = []
        var outputs: [MIDIEndpoint.ID: FakeOutput] = [:]

        init(sources: [MIDIEndpoint], destinations: [MIDIEndpoint]) {
            self.sources = sources
            self.destinations = destinations
        }

        func connect(source: MIDIEndpoint) throws {
            connected.append(source.id)
            everConnected.append(source.id)
        }
        func disconnect(source: MIDIEndpoint) { connected.removeAll { $0 == source.id } }
        func openOutput(destination: MIDIEndpoint) throws -> any MIDIOutput {
            // Like CoreMIDI's one output port: controllers sharing a destination share what it was sent.
            if let open = outputs[destination.id], !open.closed { return open }
            let output = FakeOutput()
            outputs[destination.id] = output
            return output
        }
    }

    final class FakeOSC: OSCSender, @unchecked Sendable {
        var sent: [OSCMessage] = []
        /// Each bundle as sent (#636); its messages are in `sent` too.
        var bundles: [[OSCMessage]] = []
        /// Each bundle's sequence number (#750), in order; `bundles` and `sent` leave the seq message out, so tests
        /// about the feed's contents read as before.
        var seqs: [UInt32] = []
        /// Each bundle exactly as sent, seq and all.
        var rawBundles: [[OSCMessage]] = []
        func send(_ message: OSCMessage) { sent.append(message) }
        func send(bundle messages: [OSCMessage]) {
            rawBundles.append(messages)
            var rest = messages
            if let first = rest.first, first.address == "/DeckBridge/Display/seq", case .int(let n) = first.arguments.first {
                seqs.append(UInt32(bitPattern: n))
                rest.removeFirst()
            }
            bundles.append(rest)
            sent += rest
        }
    }

    final class FakeClock: Clock, @unchecked Sendable {
        var now: Double = 0
    }

    final class FakeLog: LogSink, @unchecked Sendable {
        var lines: [String] = []
        func log(_ line: String) { lines.append(line) }
    }

    static let lc6000 = MIDIEndpoint(id: 1001, name: "DENON LC6000 PRIME")
    static let lc6000Out = MIDIEndpoint(id: 2001, name: "DENON LC6000 PRIME")

    let midi = FakeMIDISystem(sources: [MIDIEndpoint(id: 1000, name: "IAC Bus 1"), Rig.lc6000], destinations: [Rig.lc6000Out])
    let osc = FakeOSC()
    let clock = FakeClock()
    let log = FakeLog()
    let coordinator: Coordinator

    /// The latest velocity sent to each LED note on the controller's output.
    var leds: [UInt8: UInt8] {
        var out: [UInt8: UInt8] = [:]
        for case let .noteOn(_, note, velocity) in midi.outputs[Rig.lc6000Out.id]?.sent ?? [] { out[note] = velocity }
        return out
    }

    /// A rig running `mapping` as it is, such as a whole test-only profile's (#341).
    init(mapping: Mapping) {
        coordinator = Coordinator(mapping: mapping, midi: midi, osc: osc, clock: clock, log: log)
    }

    /// A rig whose mapping is the default with `override` (a JSON mapping file) merged over it.
    init(override: String? = nil) throws {
        let mapping = try override.map { try Mapping.bundledDefault(overriddenBy: Data($0.utf8)) } ?? Mapping.bundledDefault()
        coordinator = Coordinator(mapping: mapping, midi: midi, osc: osc, clock: clock, log: log)
    }
}

@Suite("Coordinator")
struct CoordinatorTests {
    @Test("Start asks Syndicate to resend its state")
    func startAsksForResend() throws {
        let rig = try Rig()
        rig.coordinator.start()
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Feedback/Resend", [.int(1)])])
    }

    @Test("Start connects the source whose name matches the mapping's input, and no other")
    func startConnectsController() throws {
        let rig = try Rig()
        rig.coordinator.start()
        #expect(rig.midi.connected == [Rig.lc6000.id])
    }

    @Test("Pressing Play sends PlayPause 1; releasing it (note off, or note on at velocity 0) sends nothing")
    func playIsATrigger() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()

        rig.coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.midi(.noteOff(channel: 0, note: 1, velocity: 0), source: Rig.lc6000.id)
        rig.coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 0), source: Rig.lc6000.id)

        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])])
    }

    @Test("The Play LED is dim (1) while stopped and full (127) while Syndicate reports Playing")
    func playLEDFollowsPlaying() throws {
        let rig = try Rig()
        rig.coordinator.start()
        #expect(rig.leds[1] == 1)

        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        #expect(rig.leds[1] == 127)

        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))
        #expect(rig.leds[1] == 1)
    }

    @Test("Feedback addresses match without regard to case")
    func feedbackIgnoresCase() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/syndicate/deck/1/playing", [.int(1)]))
        #expect(rig.leds[1] == 127)
    }

    @Test("Feedback for another deck leaves this controller's LEDs alone")
    func feedbackForOtherDeck() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        #expect(rig.leds[1] == 1)
    }

    @Test("MIDI on another channel is ignored")
    func otherChannelIgnored() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        rig.coordinator.midi(.noteOn(channel: 1, note: 1, velocity: 127), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [])
    }

    @Test("An unchanged LED isn't sent twice: repeated Playing 1 lights the Play LED once")
    func unchangedLEDNotResent() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        let playOn = rig.midi.outputs[Rig.lc6000Out.id]?.sent.filter { $0 == .noteOn(channel: 0, note: 1, velocity: 127) }
        #expect(playOn?.count == 1)
    }

    @Test("With the controller's input but no MIDI output, it still bridges: Play sends PlayPause, and stop releases (Python's no-output test)")
    func bridgesWithoutOutput() throws {
        let rig = try Rig()
        rig.midi.destinations = []
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        rig.coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)   // Cue held
        rig.coordinator.stop()
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/Cue", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)]),
        ])
        #expect(rig.midi.outputs.isEmpty)
    }
}
