@testable import ControllerBridgeCore
import Testing

/// One "shown" cache per output (#554): what the unit's lights are now, whichever layer set them. A deck select step
/// (#420) sends only the lights that differ for the new layer.
@Suite("Layer shown cache")
struct LayerShownCacheTests {
    typealias Press = PressLitButtonsTests

    static func noteOns(_ rig: Rig) -> [String] {
        (rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).compactMap {
            if case .noteOn(let channel, let note, let velocity) = $0 { "ch\(channel + 1) \(note)=\(velocity)" } else { nil }
        }
    }

    @Test("Deck select to a layer that differs only in Play (deck 2 playing): exactly that one light goes out")
    func onlyTheDifference() throws {
        let rig = try LayersTests.layered()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        Press.note(rig, 23, down: true)
        Press.note(rig, 23, down: false)
        // Play, and deck select's own press flash (#477).
        #expect(Self.noteOns(rig) == ["ch1 1=127", "ch1 23=127", "ch1 23=1"])
    }

    @Test("And back: only Play again, dim")
    func back() throws {
        let rig = try LayersTests.layered()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        Press.note(rig, 23, down: true)
        Press.note(rig, 23, down: false)
        for _ in 0..<3 {   // round to layer 1 (layers 3 and 4 show deck 3 and 4, not playing: Play dim on the first)
            rig.clock.now += 1
            Press.note(rig, 23, down: true)
            Press.note(rig, 23, down: false)
            if rig.coordinator.status.controllers[2].activeLayer {
                rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
            }
        }
        #expect(rig.coordinator.status.controllers[0].activeLayer)
        // Layers 3, 4 and 1 show the same lights: only deck select's flash goes out.
        #expect(Self.noteOns(rig).allSatisfy { $0.contains(" 23=") })
    }

    @Test("Multi-channel mode: a deck select step paints the new layer on the unit's current channel (the one deck select came on), not the layer's own")
    func unitChannel() throws {
        let rig = try LayersTests.layered()
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        LayersTests.note(rig, channel: 1, 51, 0); LayersTests.note(rig, channel: 2, 51, 127)
        LayersTests.note(rig, channel: 2, 1, 127)   // Play on ch2: the unit is in its multi-channel state, on layer 2
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/3/Playing", [.int(1)]))
        output.sent.removeAll()
        rig.clock.now = 5   // well after the unit's own layer change, so the step isn't settled with it (#553)
        // Deck select comes on ch1 (the trace: always ch1), the unit's own channel: the bridge steps to layer 3.
        LayersTests.note(rig, channel: 1, 23, 127)
        LayersTests.note(rig, channel: 1, 23, 0)
        #expect(rig.coordinator.status.controllers[2].activeLayer)
        #expect(LayersTests.channelsWritten(output) == [1])
        #expect(Self.noteOns(rig).contains("ch1 1=127"))   // deck 3's Play, where the unit takes it
    }

    /// Every LED note the layered rig paints at start.
    static func painted(_ rig: Rig) -> Set<UInt8> {
        Set((rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).compactMap { if case .noteOn(_, let note, _) = $0 { note } else { nil } })
    }

    @Test("Where the unit forgot its lights, the full set still goes after a diff step: a reconnect, the LEDs off and on, a unit-made layer change")
    func fullSetStays() throws {
        let rig = try LayersTests.layered()
        let all = Self.painted(rig)
        #expect(all.count > 30)
        rig.clock.now = 5
        Press.note(rig, 23, down: true)
        Press.note(rig, 23, down: false)
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        // A reconnect (#429).
        output.sent.removeAll()
        rig.coordinator.devicesChanged(removed: [Rig.lc6000.id])
        #expect(Self.painted(rig).isSuperset(of: all))
        // LEDs off and on.
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        rig.coordinator.setLEDs(enabled: false)
        rig.coordinator.setLEDs(enabled: true)
        #expect(Self.painted(rig).isSuperset(of: all))
        // The unit's own layer change (its layer note): its deck-select mode cleared its lights (#426).
        rig.clock.now = 10
        rig.coordinator.tick()
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        LayersTests.note(rig, channel: 1, 51, 0); LayersTests.note(rig, channel: 3, 51, 127)
        #expect(Self.painted(rig).isSuperset(of: all.subtracting([23])))
    }
}
