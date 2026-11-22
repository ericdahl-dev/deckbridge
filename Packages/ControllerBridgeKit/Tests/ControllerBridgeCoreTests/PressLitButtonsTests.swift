@testable import ControllerBridgeCore
import Testing

/// The dark buttons (#476): Beat Jump, Track Skip, the browse knob's ring, Vinyl, Pitch Bend and Param have no state to
/// show, so they're lit dim when idle (when the profile dims unlit buttons) and full while held.
@Suite("Press-lit buttons")
struct PressLitButtonsTests {
    /// The LC6000's notes for them: beat jump 3/4, track skip 5/6, the browse press 18, Vinyl 19, pitch bend 24/25,
    /// param 68/69.
    static let notes: [UInt8] = [3, 4, 5, 6, 18, 19, 24, 25, 68, 69]
    static let names = ["beat_jump_back", "beat_jump_forward", "track_prev", "track_next", "select_press", "vinyl",
                        "pitch_minus", "pitch_plus", "param_back", "param_forward"]

    static func started(_ override: String? = nil) throws -> Rig {
        let rig = try Rig(override: override)
        rig.coordinator.start()
        return rig
    }

    @Test("At start each is dim (1); with dim_unlit_buttons off, off (0)")
    func idle() throws {
        let dim = try Self.started()
        for note in Self.notes { #expect(dim.leds[note] == 1, "note \(note)") }
        let off = try Self.started(#"{ "leds": { "dim_unlit_buttons": false } }"#)
        for note in Self.notes { #expect(off.leds[note] == 0, "note \(note)") }
    }

    @Test("A profile that doesn't name them sends them nothing")
    func unnamed() throws {
        var mapping = try Mapping.bundledDefault()
        for name in Self.names { mapping.notes.buttons[name] = nil }
        let rig = Rig(mapping: mapping)
        rig.coordinator.start()
        for note in Self.notes { #expect(rig.leds[note] == nil, "note \(note)") }
    }

    static func note(_ rig: Rig, _ note: UInt8, down: Bool) {
        rig.coordinator.midi(down ? .noteOn(channel: 0, note: note, velocity: 127) : .noteOff(channel: 0, note: note, velocity: 0),
                             source: Rig.lc6000.id)
    }

    /// Vinyl's light also shows its seek mode (#540, VinylSeekTests): a press-and-release turns it on, so it's left out.
    @Test("Each goes full (127) while held and back to dim (1) on release")
    func held() throws {
        let rig = try Self.started()
        for note in Self.notes where note != 19 {
            Self.note(rig, note, down: true)
            #expect(rig.leds[note] == 127, "note \(note) held")
            Self.note(rig, note, down: false)
            #expect(rig.leds[note] == 1, "note \(note) released")
        }
    }

    @Test("With Shift held a press lights it too (Shift + Pitch Bend transposes, Shift + Beat Jump jumps a bar)")
    func shifted() throws {
        let rig = try Self.started()
        Self.note(rig, 26, down: true)   // Shift
        Self.note(rig, 24, down: true)
        #expect(rig.leds[24] == 127)
        Self.note(rig, 24, down: false)
        #expect(rig.leds[24] == 1)
    }

    @Test("Only changes go out: holding sends one full, releasing one dim")
    func onlyChanges() throws {
        let rig = try Self.started()
        let before = rig.midi.outputs[Rig.lc6000Out.id]?.sent.count ?? 0
        Self.note(rig, 3, down: true)
        Self.note(rig, 3, down: false)
        let sent = (rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).dropFirst(before)
        let note3 = sent.compactMap { if case .noteOn(_, 3, let velocity) = $0 { return velocity }; return nil }
        #expect(note3 == [127, 1])
    }

    @Test("They're the bridge's own: with stale_idle off, Syndicate's lights go off when feedback stops, these stay dim")
    func notStale() throws {
        let rig = try LivenessTests.StaleIdleRig(staleIdle: "off")
        rig.tick(at: 10.5)
        rig.tick(at: 12.5)
        #expect(rig.leds[1] == 0)   // Play: Syndicate's
        for note in Self.notes { #expect(rig.leds[note] == 1, "note \(note)") }
    }

    @Test("A deck layer change repaints them for the new layer")
    func layerChange() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: LayersTests.lc6000Layers))
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        LayersTests.switchLayer(rig, from: 1, to: 2)
        let sent = rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []
        let repainted = Set(sent.compactMap { if case .noteOn(_, let note, 1) = $0 { return note }; return nil })
        #expect(Set(Self.notes).isSubset(of: repainted))
    }
}
