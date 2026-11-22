import Foundation
@testable import ControllerBridgeCore
import Testing

/// #251: a whole profile file is checked against its own keys, not merged over the LC6000's; and two notes on the
/// same number collide only when they can arrive on the same channel.
@Suite("Channel-aware profile check")
struct ChannelAwareCheckTests {
    /// The bundled LC6000 as a whole profile file, with `change` applied to its mapping.
    static func profile(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var mapping = try JSONSerialization.jsonObject(with: Mapping.defaultMappingJSON()) as! [String: Any]
        change(&mapping)
        let file: [String: Any] = ["id": "test-ddj", "name": "Test DDJ", "device_hints": ["DDJ"], "mapping": mapping]
        // Sorted keys, so the file and its problem order are the same every run.
        return try JSONSerialization.data(withJSONObject: file, options: .sortedKeys)
    }

    static func problems(_ data: Data) -> [String] {
        do { _ = try ControllerProfile(decoding: data); return [] } catch let MappingError.invalid(list) { return list } catch { return ["\(error)"] }
    }

    /// A DDJ-like controller: a few buttons of its own, none of the LC6000's others.
    static func ddjNotes(_ mapping: inout [String: Any], pads: [Int] = Array(0...7)) {
        mapping["notes"] = ["play": 11, "cue": 12, "loop_in": 16, "loop_out": 17, "shift": 63, "pads": pads]
    }

    @Test("A whole profile that sets only its own buttons doesn't collide with LC6000 buttons it doesn't have")
    func ownKeysOnly() throws {
        let data = try Self.profile { mapping in
            Self.ddjNotes(&mapping)
            var pads = mapping["pads"] as! [String: Any]
            pads["channel"] = 8
            mapping["pads"] = pads
        }
        #expect(Self.problems(data) == [])
    }

    @Test("Pads on their own channel don't collide with a button of the same number; on the deck's channel they do")
    func padChannel() throws {
        let own = try Self.profile { mapping in
            Self.ddjNotes(&mapping, pads: [11, 1, 2, 3, 4, 5, 6, 7])          // pad 1 is note 11, like Play
            var pads = mapping["pads"] as! [String: Any]
            pads["channel"] = 8
            mapping["pads"] = pads
        }
        #expect(Self.problems(own) == [])
        let shared = try Self.profile { Self.ddjNotes(&$0, pads: [11, 1, 2, 3, 4, 5, 6, 7]) }
        #expect(Self.problems(shared) == ["notes.play: note 11 is also notes.pads[0]"])
    }

    @Test("Pads on a layer's pad_channel don't collide with buttons on the layer channels")
    func layerPadChannel() throws {
        let data = try Self.profile { mapping in
            Self.ddjNotes(&mapping, pads: [11, 1, 2, 3, 4, 5, 6, 7])
            var midi = mapping["midi"] as! [String: Any]
            midi["layers"] = [["channel": 1, "deck": 1, "pad_channel": 8], ["channel": 2, "deck": 2, "pad_channel": 10]]
            mapping["midi"] = midi
        }
        #expect(Self.problems(data) == [])
    }

    @Test("Once a layer sets its own pad channel, the others' pads are on their deck channel, as the Coordinator runs them (#323)")
    func layerPadChannelNotInherited() throws {
        let data = try Self.profile { mapping in
            Self.ddjNotes(&mapping, pads: [11, 1, 2, 3, 4, 5, 6, 7])          // pad 1 is note 11, like Play
            var pads = mapping["pads"] as! [String: Any]
            pads["channel"] = 8
            mapping["pads"] = pads
            var midi = mapping["midi"] as! [String: Any]
            midi["layers"] = [["channel": 1, "deck": 1], ["channel": 2, "deck": 2, "pad_channel": 10]]
            mapping["midi"] = midi
        }
        #expect(Self.problems(data) == ["notes.play: note 11 is also notes.pads[0]"])
    }

    /// Per-mode pad notes (#225), DDJ-like: each mode's eight pads on their own notes.
    static func modeNotes(_ mapping: inout [String: Any], hotcue: [Int] = Array(0...7), roll: [Int] = Array(112...119),
                          channel: Int? = nil) {
        var pads = mapping["pads"] as! [String: Any]
        pads["mode_notes"] = ["hotcue": hotcue, "roll": roll, "loop": Array(96...103), "slicer": Array(32...39)]
        if let channel { pads["channel"] = channel }
        mapping["pads"] = pads
    }

    @Test("Mode notes are checked (#322): two modes can't share a note; notes.pads is only their count then")
    func modeNotesShared() throws {
        let clean = try Self.profile { Self.ddjNotes(&$0); Self.modeNotes(&$0) }
        #expect(Self.problems(clean) == [], "hotcue equal to notes.pads is fine: with mode_notes, notes.pads only counts the pads")
        let shared = try Self.profile { Self.ddjNotes(&$0); Self.modeNotes(&$0, roll: [0] + Array(113...119)) }
        #expect(Self.problems(shared) == ["pads.mode_notes.hotcue[0]: note 0 is also pads.mode_notes.roll[0]"])
    }

    @Test("A mode note equal to a button's collides on a shared channel, not when the pads have their own (#322)")
    func modeNotesAndButtons() throws {
        let hotcue = [11] + Array(1...7)   // hot cue pad 1 is note 11, like Play
        let shared = try Self.profile { Self.ddjNotes(&$0); Self.modeNotes(&$0, hotcue: hotcue) }
        #expect(Self.problems(shared) == ["pads.mode_notes.hotcue[0]: note 11 is also notes.play"])
        let own = try Self.profile { Self.ddjNotes(&$0); Self.modeNotes(&$0, hotcue: hotcue, channel: 8) }
        #expect(Self.problems(own) == [])
    }

    @Test("Shift pads on a deck's channel collide with its buttons; on their own channel they don't (#343)")
    func shiftedPadChannel() throws {
        func profile(shifted: Int) throws -> Data {
            try Self.profile { mapping in
                Self.ddjNotes(&mapping, pads: [11, 1, 2, 3, 4, 5, 6, 7])      // pad 1 is note 11, like Play
                var pads = mapping["pads"] as! [String: Any]
                pads["channel"] = 8
                pads["shifted_channel"] = shifted
                mapping["pads"] = pads
            }
        }
        #expect(Self.problems(try profile(shifted: 1)) == ["notes.play: note 11 is also notes.pads[0]"])
        #expect(Self.problems(try profile(shifted: 9)) == [])
    }

    @Test("Per layer, the Shift pads' channel follows the same rule as pad_channel (#343)")
    func layerShiftedPadChannel() throws {
        let data = try Self.profile { mapping in
            Self.ddjNotes(&mapping, pads: [11, 1, 2, 3, 4, 5, 6, 7])
            var midi = mapping["midi"] as! [String: Any]
            midi["layers"] = [["channel": 1, "deck": 1, "pad_channel": 8, "shifted_pad_channel": 9],
                              ["channel": 2, "deck": 2, "pad_channel": 10, "shifted_pad_channel": 2]]
            mapping["midi"] = midi
        }
        #expect(Self.problems(data) == ["notes.play: note 11 is also notes.pads[0]"])
    }

    @Test("The LC6000 is unchanged: the bundled profile loads, and an import that reuses Back's note is still refused")
    func lc6000() throws {
        #expect(try ControllerProfile.bundled().count == 1)
        #expect(throws: MappingError.invalid(["mapping.notes.loop_in: note 16 is also notes.back"])) {
            try ControllerProfile.importing(Data(#"{"mapping": {"notes": {"loop_in": 16}}}"#.utf8),
                                            bundled: try ControllerProfile.bundled(), active: "denon-lc6000-prime")
        }
    }
}
