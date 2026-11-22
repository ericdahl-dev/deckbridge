import Foundation
@testable import ControllerBridgeCore
import Testing

/// Pad count and roll sizes from the profile (#196): 4, 8 or 16 pads, and the roll each pad plays.
@Suite("Pad count mapping")
struct PadCountMappingTests {
    @Test("Left out, the roll sizes are the LC6000's eight, 1/32 up to 4 beats")
    func defaultRollSizes() throws {
        var body = try #require(try JSONSerialization.jsonObject(with: Mapping.defaultMappingJSON()) as? [String: Any])
        body["pads"] = nil
        let mapping = try JSONDecoder().decode(Mapping.self, from: JSONSerialization.data(withJSONObject: body))
        #expect(mapping.pads.rollSizes == ["ThirtySecond", "Sixteenth", "Eighth", "Quarter", "Half", "One", "Two", "Four"])
    }

    @Test("The bundled LC6000 has 8 pads and the eight roll sizes, as before #196")
    func lc6000() throws {
        let mapping = try Mapping.bundledDefault()
        #expect(mapping.notes.pads.count == 8)
        #expect(mapping.pads.rollSizes == ["ThirtySecond", "Sixteenth", "Eighth", "Quarter", "Half", "One", "Two", "Four"])
    }
}

/// The Coordinator seam (#196). Velocities from the 0b00RRGGBB table by hand: Syndicate's default slot 1 is red
/// (255, 0, 0) → 48, slot 4 green (0, 255, 0) → 12.
@Suite("Pad count at the Coordinator")
struct PadCountCoordinatorTests {
    static let fourPads = #"{ "notes": { "pads": [32, 33, 34, 35] }, "pads": { "roll_sizes": ["Quarter", "Half", "One", "Two"] } }"#

    static func started(_ override: String?) throws -> Rig {
        let rig = try Rig(override: override)
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        return rig
    }

    /// Cues for slots 1-8, each cue in its own slot's color.
    static let eightCues = OSCMessage("/Syndicate/Deck/1/Cues", (1...8).flatMap { [OSCArgument.int(Int32($0)), .string("c\($0)")] })

    static func hold(_ rig: Rig, _ note: UInt8) -> [OSCMessage] {
        rig.osc.sent.removeAll()
        PadsTests.press(rig, note)
        return rig.osc.sent
    }

    @Test("Four pads: pad 4 holds hot cue 4, Roll pad 1 plays the profile's Quarter, Loop pad 3 sets cue loop 3")
    func fourPadOSC() throws {
        let rig = try Self.started(Self.fourPads)
        #expect(Self.hold(rig, 35) == [OSCMessage("/Syndicate/Deck/1/HotCue", [.int(4), .int(1)]),
                                       OSCMessage("/Syndicate/Deck/1/HotCue", [.int(4), .int(0)])])
        PadsTests.press(rig, PadsTests.modeRoll)
        #expect(Self.hold(rig, 32) == [OSCMessage("/Syndicate/Deck/1/SlipLoop/Quarter", [.int(1)]),
                                       OSCMessage("/Syndicate/Deck/1/SlipLoop/Quarter", [.int(0)])])
        PadsTests.press(rig, PadsTests.modeLoop)
        #expect(Self.hold(rig, 34) == [OSCMessage("/Syndicate/Deck/1/SetCueLoop", [.int(3)])])
    }

    @Test("Four pads light from an 8-slot Cues: pads 1-4 in slots 1-4's colors, and notes 36-39 are never written")
    func fourPadLEDs() throws {
        let rig = try Self.started(Self.fourPads)
        rig.coordinator.feedback(Self.eightCues)
        #expect(rig.leds[32] == 48)
        #expect(rig.leds[35] == 12)
        #expect([36, 37, 38, 39].map { rig.leds[$0] } == [nil, nil, nil, nil])
    }

    /// Sixteen pads on notes 100-115, free in the LC6000 mapping.
    static let sixteenPads = #"{ "notes": { "pads": [\#((100...115).map(String.init).joined(separator: ", "))] } }"#

    @Test("Sixteen pads: pad 8 holds hot cue 8, but pad 12 is past Syndicate's 8 cues and sends nothing (#311); pads 9-16 stay off")
    func sixteenPads() throws {
        let rig = try Self.started(Self.sixteenPads)
        #expect(Self.hold(rig, 107) == [OSCMessage("/Syndicate/Deck/1/HotCue", [.int(8), .int(1)]),
                                        OSCMessage("/Syndicate/Deck/1/HotCue", [.int(8), .int(0)])])
        #expect(Self.hold(rig, 111) == [])
        rig.coordinator.feedback(Self.eightCues)
        #expect(rig.leds[100] == 48)
        #expect((108...115).map { rig.leds[UInt8($0)] } == Array(repeating: 0, count: 8))
    }

    @Test("Sixteen pads with the default eight roll sizes: Roll pad 9 plays nothing")
    func rollPastTheList() throws {
        let rig = try Self.started(Self.sixteenPads)
        PadsTests.press(rig, PadsTests.modeRoll)
        #expect(Self.hold(rig, 108) == [])
    }

    @Test("Switching mode releases a held pad 8; held pad 12 had nothing to release")
    func modeReleasesHeldPad() throws {
        let rig = try Self.started(Self.sixteenPads)
        PadsTests.down(rig, 107)
        PadsTests.down(rig, 111)
        rig.osc.sent.removeAll()
        PadsTests.press(rig, PadsTests.modeLoop)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/HotCue", [.int(8), .int(0)])])
    }

    @Test("Loop mode: pad 12 is past Syndicate's 8 cues and sets no cue loop (#311)")
    func loopPastTheCues() throws {
        let rig = try Self.started(Self.sixteenPads)
        PadsTests.press(rig, PadsTests.modeLoop)
        #expect(Self.hold(rig, 111) == [])
    }

    @Test("Roll mode lights only the pads that have a roll size; pads 9-16 past the eight stay off (#311)")
    func rollLightsOnlySizedPads() throws {
        let rig = try Self.started(Self.sixteenPads)
        PadsTests.press(rig, PadsTests.modeRoll)
        #expect(rig.leds[100] != 0)
        #expect((108...115).map { rig.leds[UInt8($0)] } == Array(repeating: 0, count: 8))
    }

    @Test("The LC6000 is unchanged: Roll pad 1 plays ThirtySecond, and all 8 pads light from Cues")
    func lc6000() throws {
        let rig = try Self.started(nil)
        rig.coordinator.feedback(Self.eightCues)
        #expect((32...39).map { rig.leds[UInt8($0)] } == [48, 56, 60, 12, 15, 3, 35, 51])
        PadsTests.press(rig, PadsTests.modeRoll)
        #expect(Self.hold(rig, 32) == [OSCMessage("/Syndicate/Deck/1/SlipLoop/ThirtySecond", [.int(1)]),
                                       OSCMessage("/Syndicate/Deck/1/SlipLoop/ThirtySecond", [.int(0)])])
    }
}

/// The import check (#196), in plain words.
@Suite("Pad count in the import check")
struct PadCountImportTests {
    static func importing(_ json: String) throws -> ControllerProfile {
        try ControllerProfile.importing(Data(json.utf8), bundled: try ControllerProfile.bundled(), active: "denon-lc6000-prime")
    }

    @Test("A roll size is one of Syndicate's SlipLoop names; text is expected")
    func rollSizes() {
        #expect(throws: MappingError.invalid([
            #"mapping.pads.roll_sizes[2]: "Third" isn't one of ThirtySecond, Sixteenth, Eighth, Quarter, Half, One, Two, Four"#,
            #"mapping.pads.roll_sizes[3]: expected text, got 4"#,
        ])) {
            try Self.importing(#"{"mapping": {"pads": {"roll_sizes": ["Quarter", "Half", "Third", 4]}}}"#)
        }
    }

    @Test("A good four-pad import works")
    func fourPads() throws {
        let profile = try Self.importing(#"{"mapping": {"notes": {"pads": [32, 33, 34, 35]}, "pads": {"roll_sizes": ["Half"]}}}"#)
        #expect(profile.mapping.notes.pads == [32, 33, 34, 35])
        #expect(profile.mapping.pads.rollSizes == ["Half"])
    }
}
