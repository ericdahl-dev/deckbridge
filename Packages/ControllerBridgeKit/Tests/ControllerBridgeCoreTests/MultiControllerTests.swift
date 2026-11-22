import ControllerBridgeCore
import Testing

/// Several controllers in one app, each on its own deck, sharing Syndicate's one feedback stream (#25).
@Suite("Multiple controllers")
struct MultiControllerTests {
    static let unitB = MIDIEndpoint(id: 1005, name: "DENON LC6000 PRIME")
    static let unitBOut = MIDIEndpoint(id: 2005, name: "DENON LC6000 PRIME")

    /// Two LC6000s plugged in: A on deck 1, B on deck 2.
    static func twoUnits() throws -> Rig {
        let rig = try Rig()
        rig.midi.sources.append(unitB)
        rig.midi.destinations.append(unitBOut)
        rig.coordinator.start()
        rig.coordinator.setControllers([
            ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out),
            ControllerSettings(deck: 2, input: unitB, output: unitBOut),
        ])
        rig.osc.sent.removeAll()
        return rig
    }

    static func press(_ rig: Rig, _ note: UInt8, from source: MIDIEndpoint, channel: UInt8 = 0) {
        rig.coordinator.midi(.noteOn(channel: channel, note: note, velocity: 127), source: source.id)
    }

    /// The latest velocity on each LED note of an output, on one channel.
    static func leds(_ rig: Rig, _ output: MIDIEndpoint, channel: UInt8 = 0) -> [UInt8: UInt8] {
        var out: [UInt8: UInt8] = [:]
        for case let .noteOn(c, note, velocity) in rig.midi.outputs[output.id]?.sent ?? [] where c == channel { out[note] = velocity }
        return out
    }

    @Test("Two units on decks 1 and 2: each one's Play goes to its own deck")
    func twoUnitsTwoDecks() throws {
        let rig = try Self.twoUnits()
        Self.press(rig, 1, from: Rig.lc6000)
        Self.press(rig, 1, from: Self.unitB)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)]),
            OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)]),
        ])
        #expect(rig.coordinator.status.controllers.map(\.deck) == [1, 2])
        #expect(rig.coordinator.status.controllers.map(\.connected) == [true, true])
        #expect(Set(rig.midi.connected) == [Rig.lc6000.id, Self.unitB.id])
    }

    @Test("One feedback stream fans out: deck 2's Playing lights only unit B; a deck nobody drives changes no LEDs")
    func feedbackFansOut() throws {
        let rig = try Self.twoUnits()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        #expect(Self.leds(rig, Self.unitBOut)[1] == 127)
        #expect(Self.leds(rig, Rig.lc6000Out)[1] == 1)

        let sentA = rig.midi.outputs[Rig.lc6000Out.id]?.sent.count
        let sentB = rig.midi.outputs[Self.unitBOut.id]?.sent.count
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/3/Playing", [.int(1)]))
        #expect(rig.midi.outputs[Rig.lc6000Out.id]?.sent.count == sentA)
        #expect(rig.midi.outputs[Self.unitBOut.id]?.sent.count == sentB)
    }

    @Test("Unplugging unit B releases B's holds only; unit A keeps its hold and keeps working")
    func unplugOne() throws {
        let rig = try Self.twoUnits()
        Self.press(rig, 2, from: Rig.lc6000)   // Cue held on deck 1
        Self.press(rig, 2, from: Self.unitB)   // Cue held on deck 2
        rig.osc.sent.removeAll()

        rig.midi.sources.removeAll { $0 == Self.unitB }
        rig.midi.destinations.removeAll { $0 == Self.unitBOut }
        rig.coordinator.devicesChanged()
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/Cue", [.int(0)])])
        #expect(rig.coordinator.status.controllers.map(\.connected) == [true, false])

        // Unit A still holds CUE, so its PLAY latches the preview (#360).
        Self.press(rig, 1, from: Rig.lc6000)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
    }

    @Test("Two controllers on one device, told apart by channel: each channel drives its own deck and LEDs")
    func oneDeviceTwoChannels() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setControllers([
            ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out, channel: 1),
            ControllerSettings(deck: 2, input: Rig.lc6000, output: Rig.lc6000Out, channel: 2),
        ])
        #expect(rig.midi.connected == [Rig.lc6000.id])
        rig.osc.sent.removeAll()

        Self.press(rig, 1, from: Rig.lc6000, channel: 0)
        Self.press(rig, 1, from: Rig.lc6000, channel: 1)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)]),
            OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)]),
        ])
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        #expect(Self.leds(rig, Rig.lc6000Out, channel: 1)[1] == 127)
        #expect(Self.leds(rig, Rig.lc6000Out, channel: 0)[1] == 1)
    }

    @Test("Automatic with two entries: each takes its own unit; with one unit, the second waits for another")
    func automaticDoesNotDoubleClaim() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setControllers([
            ControllerSettings(deck: 1, input: nil, output: nil),
            ControllerSettings(deck: 2, input: nil, output: nil),
        ])
        #expect(rig.midi.connected == [Rig.lc6000.id])
        #expect(rig.coordinator.status.controllers.map(\.connected) == [true, false])

        rig.midi.sources.append(Self.unitB)
        rig.midi.destinations.append(Self.unitBOut)
        rig.coordinator.devicesChanged()
        #expect(rig.midi.connected == [Rig.lc6000.id, Self.unitB.id])
        rig.osc.sent.removeAll()
        Self.press(rig, 1, from: Self.unitB)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)])])
    }

    @Test("Either unit's browse works at any time, and each loads to its own deck")
    func browseFromEither() throws {
        let rig = try Self.twoUnits()
        Self.press(rig, 18, from: Self.unitB)    // select press: load
        Self.press(rig, 18, from: Rig.lc6000)
        Self.press(rig, 6, from: Self.unitB)     // track next
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Browser/L2", [.int(1)]),
            OSCMessage("/Syndicate/Browser/L1", [.int(1)]),
            OSCMessage("/Syndicate/Browser/Down", [.int(1)]),
        ])
    }

    @Test("Removing an entry releases its holds and closes its ports; the others keep going")
    func removeEntry() throws {
        let rig = try Self.twoUnits()
        Self.press(rig, 2, from: Self.unitB)     // Cue held on deck 2
        rig.osc.sent.removeAll()

        rig.coordinator.setControllers([ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)])
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/Cue", [.int(0)])])
        #expect(rig.midi.connected == [Rig.lc6000.id])
        #expect(rig.coordinator.status.controllers.map(\.deck) == [1])
        Self.press(rig, 1, from: Self.unitB)
        #expect(rig.osc.sent.count == 1)
    }
}
