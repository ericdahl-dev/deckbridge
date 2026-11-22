import ControllerBridgeCore
import Foundation
import Testing

/// The pads in exact colors (#531): with the color message on, each pad takes Denon's color message (exact RGB, 7 bits
/// a channel) in place of the 64-color note-on.
@Suite("Pads in exact color")
struct PadColorMessageTests {
    typealias Ring = RingColorMessageTests

    /// What a pad shows on the unit: the last write to its note, a color message or a note-on.
    static func shows(_ output: Rig.FakeOutput, _ note: UInt8) -> String? {
        for write in output.writes.reversed() {
            switch write {
            case .color(let m) where m.note == note: return "color \(m.red) \(m.green) \(m.blue)"
            case .event(.noteOn(_, let n, let velocity)) where n == note: return "note-on \(velocity)"
            default: continue
            }
        }
        return nil
    }

    static func cues(_ rig: Rig, deck: Int = 1, _ slots: [Int32]) {
        let arguments = slots.enumerated().flatMap { [OSCArgument.int($1), .string("c\($0 + 1)")] }
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/\(deck)/Cues", arguments))
    }

    /// A started LC6000 on deck 1 with the color message on and a track loaded; palette slots 2 and 4 two close colors.
    static func loaded() throws -> Rig {
        let rig = try Ring.exact(deck: 1)
        Ring.palette(rig, slot: 2, 200, 100, 50)
        Ring.palette(rig, slot: 4, 202, 100, 50)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        return rig
    }

    @Test("Hot cue pads show their palette colors exactly: two close colors differ; an empty pad is off; no pad note-on")
    func hotCues() throws {
        let rig = try Self.loaded()
        Self.cues(rig, [2, 4, 0, 0, 0, 0, 0, 0])
        let output = try Ring.output(rig)
        #expect(Self.shows(output, 32) == "color 100 50 25")
        #expect(Self.shows(output, 33) == "color 101 50 25")
        #expect(Self.shows(output, 34) == "color 0 0 0")
        #expect(!output.sent.contains { if case .noteOn(_, 32...39, let v) = $0 { v > 0 } else { false } })
    }

    @Test("A held pad is brighter in its own color: its strongest channel at full, exact; released, it's back")
    func heldPad() throws {
        let rig = try Self.loaded()
        Self.cues(rig, [2, 4, 0, 0, 0, 0, 0, 0])
        let output = try Ring.output(rig)
        PadsTests.down(rig, 32)
        #expect(Self.shows(output, 32) == "color 127 63 31")   // (255, 127, 63): 200, 100, 50 scaled up
        PadsTests.up(rig, 32)
        #expect(Self.shows(output, 32) == "color 100 50 25")
    }

    @Test("Roll, Loop and Slicer pads use their mode colors exactly, and go off where the table goes off")
    func modeColors() throws {
        let rig = try Self.loaded()
        Self.cues(rig, [2, 4, 0, 0, 0, 0, 0, 0])
        let output = try Ring.output(rig)
        PadsTests.press(rig, 28)   // Roll: every pad with a roll size (the LC6000's 8), in the roll color 255, 140, 0
        #expect((32...39).map { Self.shows(output, UInt8($0)) } == Array(repeating: "color 127 70 0", count: 8))
        PadsTests.press(rig, 30)   // Loop: the pads with a cue, in the loop color 0, 255, 0; the rest off
        #expect(Self.shows(output, 32) == "color 0 127 0")
        #expect(Self.shows(output, 33) == "color 0 127 0")
        #expect(Self.shows(output, 34) == "color 0 0 0")
        PadsTests.press(rig, 29)   // Slicer: off, as with the table
        #expect((32...39).map { Self.shows(output, UInt8($0)) } == Array(repeating: "color 0 0 0", count: 8))
    }

    @Test("A layer change leaves each pad showing the new deck's color, both layer modes, also a pad the same color as on the old deck")
    func layerChange() throws {
        for multiChannel in [false, true] {
            let rig = try LayersTests.layered()
            rig.coordinator.setColorMessages(true)
            Ring.palette(rig, slot: 2, 200, 100, 50)
            for deck in [1, 2] { rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/\(deck)/Loaded", [.int(1)])) }
            Self.cues(rig, deck: 1, [2, 2, 0, 0, 0, 0, 0, 0])
            Self.cues(rig, deck: 2, [2, 0, 0, 0, 0, 0, 0, 0])
            let output = try Ring.output(rig)
            #expect(Self.shows(output, 33) == "color 100 50 25", "deck 1 in front")
            if multiChannel {
                LayersTests.note(rig, channel: 1, 51, 0); LayersTests.note(rig, channel: 2, 51, 127)
                LayersTests.note(rig, channel: 2, 1, 127)   // Play on ch2: controls on ch2
            } else {
                LayersTests.note(rig, channel: 2, 51, 127)
            }
            // Pad 1 has the same color on both decks: the shared light cache (#554) rightly skips it, since the unit
            // already shows it. What counts is the last write per pad.
            #expect(Self.shows(output, 32) == "color 100 50 25", "multi-channel: \(multiChannel)")
            #expect(Self.shows(output, 33) == "color 0 0 0", "multi-channel: \(multiChannel)")
        }
    }
}
