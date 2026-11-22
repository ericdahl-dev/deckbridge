import Foundation
@testable import ControllerBridgeCore
import Testing

/// Pads on their own MIDI channel (#224), as on the Pioneer DDJ-400/FLX4 (pads on 8 and 10) and Denon MC7000 (5-8).
@Suite("Pad channel mapping")
struct PadChannelMappingTests {
    @Test("Left out, pads share the deck's channel: the bundled LC6000 has no pad channel anywhere")
    func lc6000() throws {
        let mapping = try Mapping.bundledDefault()
        #expect(mapping.pads.channel == nil)
        #expect(mapping.midi.layers.map(\.padChannel) == [nil, nil, nil, nil])
    }

    @Test("A profile sets the pad channel for its deck, and for each deck layer")
    func decodes() throws {
        let pads = try JSONDecoder().decode(Mapping.Pads.self, from: Data(#"{ "channel": 8 }"#.utf8))
        #expect(pads.channel == 8)
        let layer = try JSONDecoder().decode(Mapping.Layer.self, from: Data(#"{ "channel": 2, "deck": 2, "pad_channel": 10 }"#.utf8))
        #expect(layer == Mapping.Layer(channel: 2, deck: 2, padChannel: 10))
        let plain = try JSONDecoder().decode(Mapping.Layer.self, from: Data(#"{ "channel": 3, "deck": 3 }"#.utf8))
        #expect(plain.padChannel == nil)
    }
}

/// The Coordinator seam (#224): a test-only profile whose pads (notes 32-39) are on channel 8, its other controls on 1.
/// Velocities by hand from the 0b00RRGGBB table: Syndicate's default slot 1 red (255, 0, 0) → 48.
@Suite("Pad channel at the Coordinator")
struct PadChannelCoordinatorTests {
    static let ch8 = #"{ "pads": { "channel": 8 } }"#

    static func started(_ override: String?) throws -> Rig {
        let rig = try Rig(override: override)
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        return rig
    }

    /// Presses and releases `note` on MIDI channel `channel` (1-16).
    static func press(_ rig: Rig, _ note: UInt8, channel: UInt8) {
        rig.coordinator.midi(.noteOn(channel: channel - 1, note: note, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.midi(.noteOff(channel: channel - 1, note: note, velocity: 0), source: Rig.lc6000.id)
    }

    /// The last velocity written to `note` on `channel` (1-16).
    static func led(_ rig: Rig, _ note: UInt8, channel: UInt8) -> UInt8? {
        var out: UInt8?
        for case let .noteOn(ch, n, velocity) in rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? [] where ch == channel - 1 && n == note {
            out = velocity
        }
        return out
    }

    static let cues = OSCMessage("/Syndicate/Deck/1/Cues", (1...8).flatMap { [OSCArgument.int(Int32($0)), .string("c\($0)")] })

    @Test("Pad 1 on channel 8 holds hot cue 1; the same note on channel 1 isn't a pad")
    func padsOnTheirChannel() throws {
        let rig = try Self.started(Self.ch8)
        Self.press(rig, 32, channel: 8)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/HotCue", [.int(1), .int(1)]),
                                 OSCMessage("/Syndicate/Deck/1/HotCue", [.int(1), .int(0)])])
        rig.osc.sent.removeAll()
        Self.press(rig, 32, channel: 1)
        #expect(rig.osc.sent == [])
    }

    @Test("With the pads on their own channel, a pad note equal to a button's on the deck's channel is the button: Play plays (#322)")
    func sharedNumberOtherChannel() throws {
        // A DDJ-like profile: pad 1 is note 1 on channel 8, Play is note 1 on channel 1. The check allows it (#251).
        let rig = try Self.started(#"{ "pads": { "channel": 8 }, "notes": { "pads": [1, 33, 34, 35, 36, 37, 38, 39] } }"#)
        Self.press(rig, 1, channel: 1)
        #expect(rig.osc.sent.map(\.address).contains("/Syndicate/Deck/1/PlayPause"))
        #expect(!rig.osc.sent.map(\.address).contains("/Syndicate/Deck/1/HotCue"))
        rig.osc.sent.removeAll()
        Self.press(rig, 1, channel: 8)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/HotCue", [.int(1), .int(1)]),
                                 OSCMessage("/Syndicate/Deck/1/HotCue", [.int(1), .int(0)])])
    }

    @Test("Pad LEDs go out on channel 8 and button LEDs stay on 1: pad 1 red (48) on 8, Hot Cue's button (27) full on 1")
    func ledsOnTheirChannels() throws {
        let rig = try Self.started(Self.ch8)
        rig.coordinator.feedback(Self.cues)
        #expect(Self.led(rig, 32, channel: 8) == 48)
        #expect(Self.led(rig, 32, channel: 1) == nil)
        #expect(Self.led(rig, 27, channel: 1) == 127)
    }

    @Test("The LED sweep's color pass lights the pads on their channel (8) and the ring on the deck's (1)")
    func sweepOnPadChannel() throws {
        let rig = try Self.started(Self.ch8)
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        rig.coordinator.startLEDSweep()
        let sent = rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []
        let pads = sent.filter { if case .noteOn(_, let n, _) = $0 { return (32...39).contains(n) }; return false }
        #expect(pads.count == 8)
        #expect(pads.allSatisfy { if case .noteOn(7, _, 0) = $0 { return true }; return false })
        let ring = try Mapping.bundledDefault().leds.ring
        #expect(sent.contains(.noteOn(channel: 0, note: UInt8(ring), velocity: 0)))
    }
}

/// Deck layers with their own pad channels (#224), as a DDJ-400/FLX4 profile would set them: deck 1's pads on 8,
/// deck 2's on 10. On the LC6000 rig's four-layer setup, with layers 3 and 4 keeping their deck's channel.
@Suite("Pad channel per layer")
struct PadChannelLayersTests {
    static let layers = [
        Mapping.Layer(channel: 1, deck: 1, padChannel: 8), Mapping.Layer(channel: 2, deck: 2, padChannel: 10),
        Mapping.Layer(channel: 3, deck: 3), Mapping.Layer(channel: 4, deck: 4),
    ]
    static let override = #"""
        { "midi": { "layers": [ { "channel": 1, "deck": 1, "pad_channel": 8 }, { "channel": 2, "deck": 2, "pad_channel": 10 },
                                { "channel": 3, "deck": 3 }, { "channel": 4, "deck": 4 } ] } }
        """#

    static func layered() throws -> Rig {
        let rig = try Rig(override: override)
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: layers
        ))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))
        rig.osc.sent.removeAll()
        return rig
    }

    @Test("With layer 2 in front, pad 1 on channel 10 holds deck 2's hot cue 1, and deck 2's cue lights on channel 10")
    func layerTwo() throws {
        let rig = try Self.layered()
        LayersTests.note(rig, channel: 1, 51, 0); LayersTests.note(rig, channel: 2, 51, 127)
        LayersTests.note(rig, channel: 2, 1, 127)       // Play on ch2: layer 2 in front
        rig.osc.sent.removeAll()
        PadChannelCoordinatorTests.press(rig, 32, channel: 10)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/HotCue", [.int(1), .int(1)]),
                                 OSCMessage("/Syndicate/Deck/2/HotCue", [.int(1), .int(0)])])
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Cues", [.int(1), .string("c1")]))
        #expect(PadChannelCoordinatorTests.led(rig, 32, channel: 10) == 48)
    }
}

/// #323: the top-level pads.channel and each layer's pad_channel. A layer that sets none inherits the top-level one only
/// when no layer sets its own; and a pad on a layer's pad channel brings that layer to the front.
@Suite("Pad channel: layers and the top-level value")
struct PadChannelInheritanceTests {
    static func layered(_ override: String, layers: [Mapping.Layer]) throws -> Rig {
        let rig = try Rig(override: override)
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: layers
        ))
        rig.osc.sent.removeAll()
        return rig
    }

    static func hotCues(_ rig: Rig) -> [String] {
        rig.osc.sent.filter { $0.address.hasSuffix("/HotCue") && $0.arguments.last == .int(1) }.map(\.address)
    }

    /// pads.channel 8, and only layer 2 sets its own (10).
    static let mixed = #"""
        { "pads": { "channel": 8 },
          "midi": { "layers": [ { "channel": 1, "deck": 1 }, { "channel": 2, "deck": 2, "pad_channel": 10 },
                                { "channel": 3, "deck": 3 }, { "channel": 4, "deck": 4 } ] } }
        """#
    static let mixedLayers = [
        Mapping.Layer(channel: 1, deck: 1), Mapping.Layer(channel: 2, deck: 2, padChannel: 10),
        Mapping.Layer(channel: 3, deck: 3), Mapping.Layer(channel: 4, deck: 4),
    ]

    @Test("When a layer sets its own pad channel, the others don't inherit pads.channel: one press on 8 fires no deck")
    func noInheritanceWhenMixed() throws {
        let rig = try Self.layered(Self.mixed, layers: Self.mixedLayers)
        PadChannelCoordinatorTests.press(rig, 32, channel: 8)
        #expect(Self.hotCues(rig) == [])
    }

    @Test("A pad on a layer's own pad channel brings that layer to the front: ch10 is layer 2's, so deck 2 plays")
    func padBringsItsLayer() throws {
        let rig = try Self.layered(Self.mixed, layers: Self.mixedLayers)
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, false, false, false])
        PadChannelCoordinatorTests.press(rig, 32, channel: 10)
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, true, false, false])
        #expect(Self.hotCues(rig) == ["/Syndicate/Deck/2/HotCue"])
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Cues", [.int(1), .string("c1")]))
        #expect(PadChannelCoordinatorTests.led(rig, 32, channel: 10) == 48, "deck 2's pads light, now that it's in front")
    }

    @Test("On a pad channel every layer shares (pads.channel only), a pad plays the deck in front, not all four")
    func sharedPadChannelPlaysTheFront() throws {
        let layers = (1...4).map { Mapping.Layer(channel: $0, deck: $0) }
        let rig = try Self.layered(#"""
            { "pads": { "channel": 8 },
              "midi": { "layers": [ { "channel": 1, "deck": 1 }, { "channel": 2, "deck": 2 },
                                    { "channel": 3, "deck": 3 }, { "channel": 4, "deck": 4 } ] } }
            """#, layers: layers)
        LayersTests.note(rig, channel: 3, 51, 127)       // layer 3 in front
        rig.osc.sent.removeAll()
        PadChannelCoordinatorTests.press(rig, 32, channel: 8)
        #expect(Self.hotCues(rig) == ["/Syndicate/Deck/3/HotCue"])
    }
}

/// The LC6000 is unchanged by #224: no pad channel, so its pads play and light on the deck's channel.
@Suite("Pad channel: the LC6000 unchanged")
struct PadChannelLC6000Tests {
    @Test("Pad 1 on channel 1 holds hot cue 1, and lights red (48) on channel 1")
    func flat() throws {
        let rig = try PadChannelCoordinatorTests.started(nil)
        PadChannelCoordinatorTests.press(rig, 32, channel: 1)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/HotCue", [.int(1), .int(1)]),
                                 OSCMessage("/Syndicate/Deck/1/HotCue", [.int(1), .int(0)])])
        rig.coordinator.feedback(PadChannelCoordinatorTests.cues)
        #expect(PadChannelCoordinatorTests.led(rig, 32, channel: 1) == 48)
    }

    @Test("Normal mode on layer 2: deck 2's pad LEDs still go out on channel 1, where the unit's controls are (#79)")
    func layeredNormalMode() throws {
        let rig = try LayersTests.layered()
        LayersTests.note(rig, channel: 1, 51, 0); LayersTests.note(rig, channel: 2, 51, 127)
        LayersTests.note(rig, channel: 1, 1, 127)       // Play on ch1: normal mode, layer 2 in front
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Cues", [.int(1), .string("c1")]))
        #expect(PadChannelCoordinatorTests.led(rig, 32, channel: 1) == 48)
        #expect(PadChannelCoordinatorTests.led(rig, 32, channel: 2) == nil)
    }
}

/// The import check (#224), in plain words.
@Suite("Pad channel in the import check")
struct PadChannelImportTests {
    @Test("A pad channel is a MIDI channel, 1-16, for the deck and for each layer")
    func ranges() {
        #expect(Mapping.problems(in: Data(#"{"pads": {"channel": 17}}"#.utf8)) == ["pads.channel: 17 is out of range, expected 1-16"])
        #expect(Mapping.problems(in: Data(#"{"midi": {"layers": [{"channel": 1, "deck": 1, "pad_channel": 0}]}}"#.utf8))
            == ["midi.layers[0].pad_channel: 0 is out of range, expected 1-16"])
    }

    @Test("A pad channel is a number")
    func wrongType() {
        #expect(Mapping.problems(in: Data(#"{"pads": {"channel": "eight"}}"#.utf8)) == [#"pads.channel: expected a whole number, got "eight""#])
    }
}

/// Shift done in hardware on the pads' own channel (#324): the DDJ-400's Shift pads are on channels 9 (deck 1) and 11
/// (deck 2), next to its pads on 8 and 10.
@Suite("Shifted pad channel mapping")
struct ShiftedPadChannelMappingTests {
    @Test("Left out, there's none; the LC6000 has none; a profile sets one for its deck and one per layer")
    func decodes() throws {
        let lc6000 = try Mapping.bundledDefault()
        #expect(lc6000.pads.shiftedChannel == nil)
        #expect(lc6000.midi.layers.map(\.shiftedPadChannel) == [nil, nil, nil, nil])
        let pads = try JSONDecoder().decode(Mapping.Pads.self, from: Data(#"{ "channel": 8, "shifted_channel": 9 }"#.utf8))
        #expect(pads.shiftedChannel == 9)
        let layer = try JSONDecoder().decode(Mapping.Layer.self,
                                             from: Data(#"{ "channel": 2, "deck": 2, "pad_channel": 10, "shifted_pad_channel": 11 }"#.utf8))
        #expect(layer == Mapping.Layer(channel: 2, deck: 2, padChannel: 10, shiftedPadChannel: 11))
    }

    @Test("The import check knows both keys and their range")
    func checked() throws {
        #expect(Mapping.problems(in: Data(#"{"pads": {"channel": 8, "shifted_channel": 9}}"#.utf8)) == [])
        #expect(Mapping.problems(in: Data(#"{"pads": {"shifted_channel": 17}}"#.utf8))
            == ["pads.shifted_channel: 17 is out of range, expected 1-16"])
        #expect(Mapping.problems(in: Data(#"{"midi": {"layers": [{"channel": 1, "deck": 1, "shifted_pad_channel": 0}]}}"#.utf8))
            == ["midi.layers[0].shifted_pad_channel: 0 is out of range, expected 1-16"])
    }
}

/// The Coordinator seam (#324). On a playing deck a Shift pad plays as its pad (on a stopped one it goes to the cue,
/// paused: #358, ShiftCuePausedTests); before #324, the DDJ-400's Shift pads did nothing at all.
@Suite("Shifted pad channel at the Coordinator")
struct ShiftedPadChannelCoordinatorTests {
    static func hotCues(_ rig: Rig) -> [String] { PadChannelInheritanceTests.hotCues(rig) }

    @Test("A pad on the shifted channel (9) is that pad with Shift, the same as Shift held and the pad on 8 (deck playing)")
    func shiftedChannel() throws {
        let override = #"{ "pads": { "channel": 8, "shifted_channel": 9 } }"#
        let viaShift = try PadChannelCoordinatorTests.started(override)
        viaShift.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        viaShift.coordinator.midi(.noteOn(channel: 0, note: 26, velocity: 127), source: Rig.lc6000.id)   // Shift
        viaShift.osc.sent.removeAll()
        PadChannelCoordinatorTests.press(viaShift, 32, channel: 8)
        let shifted = try PadChannelCoordinatorTests.started(override)
        shifted.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        shifted.osc.sent.removeAll()
        PadChannelCoordinatorTests.press(shifted, 32, channel: 9)
        #expect(shifted.osc.sent == viaShift.osc.sent)
        #expect(Self.hotCues(shifted) == ["/Syndicate/Deck/1/HotCue"])
    }

    @Test("Per layer: deck 2's Shift pads on 11 bring layer 2 to the front and play deck 2 (deck playing)")
    func perLayer() throws {
        let layers = [Mapping.Layer(channel: 1, deck: 1, padChannel: 8, shiftedPadChannel: 9),
                      Mapping.Layer(channel: 2, deck: 2, padChannel: 10, shiftedPadChannel: 11)]
        let rig = try PadChannelInheritanceTests.layered(#"""
            { "midi": { "layers": [ { "channel": 1, "deck": 1, "pad_channel": 8, "shifted_pad_channel": 9 },
                                    { "channel": 2, "deck": 2, "pad_channel": 10, "shifted_pad_channel": 11 } ] } }
            """#, layers: layers)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        rig.osc.sent.removeAll()
        PadChannelCoordinatorTests.press(rig, 32, channel: 11)
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, true])
        #expect(Self.hotCues(rig) == ["/Syndicate/Deck/2/HotCue"])
    }

    @Test("The LC6000, with no shifted channel, ignores a pad on channel 9")
    func lc6000() throws {
        let rig = try PadChannelCoordinatorTests.started(nil)
        PadChannelCoordinatorTests.press(rig, 32, channel: 9)
        #expect(Self.hotCues(rig) == [])
    }
}
