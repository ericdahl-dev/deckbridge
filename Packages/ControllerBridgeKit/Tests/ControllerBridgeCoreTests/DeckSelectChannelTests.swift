@testable import ControllerBridgeCore
import Testing

/// A deck select step (#420) moves only the bridge's layer: the unit's selected deck, and so the one channel whose
/// note-ons it takes (agent2's #481 reading), stays. Before #554 the step painted the new layer on its own channel,
/// which the unit dropped: on the unit, a step from deck 1 (stopped) to deck 2 (playing) left Play as deck 1's.
@Suite("Deck select paints on the unit's channel")
struct DeckSelectChannelTests {
    static func noteOns(_ rig: Rig) -> [String] {
        (rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).compactMap {
            if case .noteOn(let channel, let note, let velocity) = $0 { "ch\(channel + 1) \(note)=\(velocity)" } else { nil }
        }
    }

    /// The unit in its multi-channel state, on its layer 1: a control came on ch2 once, then its layer note on ch1.
    static func multiChannelOnLayer1() throws -> Rig {
        let rig = try LayersTests.layered()
        LayersTests.note(rig, channel: 1, 51, 0); LayersTests.note(rig, channel: 2, 51, 127)
        LayersTests.note(rig, channel: 2, 1, 127)
        LayersTests.note(rig, channel: 2, 51, 0); LayersTests.note(rig, channel: 1, 51, 127)
        rig.clock.now = 5   // well after the unit's own layer changes, so a step is a lone one (#553)
        rig.coordinator.tick()   // and they've settled
        return rig
    }

    @Test("Deck 2 playing, deck 1 stopped, a deck select step 1 to 2: Play goes out lit on ch1, where deck select came")
    func playOnUnitChannel() throws {
        let rig = try Self.multiChannelOnLayer1()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        #expect(rig.coordinator.status.controllers[0].activeLayer)
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        LayersTests.note(rig, channel: 1, 23, 127)
        LayersTests.note(rig, channel: 1, 23, 0)
        #expect(rig.coordinator.status.controllers[1].activeLayer)
        #expect(Self.noteOns(rig).contains("ch1 1=127"))
        #expect(!Self.noteOns(rig).contains { !$0.hasPrefix("ch1 ") })
    }

    @Test("The deck select light flashes full while pressed, on ch1 too, and goes back to dim")
    func flash() throws {
        let rig = try Self.multiChannelOnLayer1()
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        LayersTests.note(rig, channel: 1, 23, 127)
        #expect(Self.noteOns(rig).last { $0.hasSuffix(" 23=127") || $0.hasSuffix(" 23=1") } == "ch1 23=127")
        LayersTests.note(rig, channel: 1, 23, 0)
        #expect(Self.noteOns(rig).last { $0.contains(" 23=") } == "ch1 23=1")
    }

    @Test("With no layers, deck select's light is dim, full while pressed")
    func flashAlone() throws {
        let rig = try PressLitButtonsTests.started()
        #expect(rig.leds[23] == 1)
        PressLitButtonsTests.note(rig, 23, down: true)
        #expect(rig.leds[23] == 127)
        PressLitButtonsTests.note(rig, 23, down: false)
        #expect(rig.leds[23] == 1)
    }
}
