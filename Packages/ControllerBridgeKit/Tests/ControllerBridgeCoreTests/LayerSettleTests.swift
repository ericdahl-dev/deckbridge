@testable import ControllerBridgeCore
import Testing

/// Rapid deck layer steps (#428): on the unit, four quick deck select presses (about 160 note-ons, four color messages
/// and four display switches in two seconds) hung it. The layer switches at once for the controls. A lone step repaints
/// at once; steps that follow within the settle interval wait, and the last layer is repainted once when they settle.
@Suite("Layer settle")
struct LayerSettleTests {
    typealias Press = PressLitButtonsTests

    static func ledWrites(_ rig: Rig) -> Int {
        (rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).filter { if case .noteOn = $0 { true } else { false } }.count
    }

    /// Decks 2 and 4 playing: every step changes Play (note 1), full on layers 2 and 4, dim on 1 and 3, so each
    /// repaint sends exactly one write to it (#554: a step sends only the lights that differ).
    static func alternating() throws -> Rig {
        let rig = try CensorDeckSelectLightsTests.layered()
        for deck in [2, 4] { rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/\(deck)/Playing", [.int(1)])) }
        return rig
    }

    /// Writes to Play (note 1) so far.
    static func playWrites(_ rig: Rig) -> [UInt8] {
        (rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).compactMap { if case .noteOn(_, 1, let v) = $0 { v } else { nil } }
    }

    @Test("A lone step repaints at once, as before")
    func lone() throws {
        let rig = try Self.alternating()
        rig.clock.now = 10
        let before = Self.playWrites(rig).count
        Press.note(rig, 23, down: true)
        #expect(Self.playWrites(rig).dropFirst(before) == [127])
    }

    @Test("Four steps 0.25 s apart: the first repaints at once, the rest wait and the last layer is repainted once")
    func coalesced() throws {
        let rig = try Self.alternating()
        rig.clock.now = 10
        rig.coordinator.tick()
        let start = Self.playWrites(rig).count
        for step in 0..<4 {
            rig.clock.now = 10 + Double(step) * 0.25
            Press.note(rig, 23, down: true)
            Press.note(rig, 23, down: false)
            rig.coordinator.tick()
        }
        #expect(Self.playWrites(rig).dropFirst(start) == [127])   // layer 2 at once; steps 2-4 wait
        rig.clock.now = 10.75 + LayerSettle.interval
        rig.coordinator.tick()
        #expect(Self.playWrites(rig).dropFirst(start) == [127, 1])   // then layer 1, once
        rig.clock.now = 12
        rig.coordinator.tick()
        #expect(Self.playWrites(rig).dropFirst(start) == [127, 1])
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [true, false, false, false])
    }

    /// Every LED write so far (note-ons; color messages aren't recorded by the fake output).
    static func ledNoteOns(_ rig: Rig) -> [String] {
        (rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).compactMap {
            if case .noteOn(let channel, let note, let velocity) = $0 { "ch\(channel + 1) \(note)=\(velocity)" } else { nil }
        }
    }

    @Test("The steps seen on the unit (16:35:26.47, 27.26, 27.84, 28.22), decks 2 and 4 playing: each is a lone step at 0.3 s, and the four send 12 note-ons, not about 156")
    func observed() throws {
        let rig = try Self.alternating()
        rig.clock.now = 26
        rig.coordinator.tick()
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        for time in [26.47, 27.26, 27.84, 28.22] {
            rig.clock.now = time
            Press.note(rig, 23, down: true)
            Press.note(rig, 23, down: false)
            rig.coordinator.tick()
        }
        rig.clock.now = 30
        rig.coordinator.tick()
        // Each step: Play (the one light that differs) and deck select's press flash, full then dim.
        #expect(Self.ledNoteOns(rig) == ["ch1 1=127", "ch1 23=127", "ch1 23=1", "ch1 1=1", "ch1 23=127", "ch1 23=1",
                                          "ch1 1=127", "ch1 23=127", "ch1 23=1", "ch1 1=1", "ch1 23=127", "ch1 23=1"])
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [true, false, false, false])
    }

    @Test("The controls switch at once: a press right after a step goes to the new layer's deck")
    func controlsAtOnce() throws {
        let rig = try CensorDeckSelectLightsTests.layered()
        rig.osc.sent.removeAll()
        Press.note(rig, 23, down: true)
        Press.note(rig, 23, down: false)
        rig.coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)   // Play
        #expect(rig.osc.sent.contains(OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)])))
    }
}
