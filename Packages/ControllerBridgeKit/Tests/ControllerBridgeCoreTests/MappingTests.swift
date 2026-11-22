import Foundation
import ControllerBridgeCore
import Testing

/// Expected values are typed from lc6000_bridge/default_mapping.toml, the Python default mapping (removed in #30, in the git history), except
/// `osc.feedback_host`: the app listens on loopback by default (#32), where Python listened on 0.0.0.0, and
/// `leds.beat_pulse` / `leds.pulse_ms` (#23) and `osc.feedback_quiet_ms` / `osc.feedback_answer_ms` /
/// `leds.stale_idle` (#21), which Python never had.
@Suite("Mapping")
struct MappingTests {
    @Test("The bundled default mapping carries the Python default values")
    func defaultMapping() throws {
        let mapping = try Mapping.bundledDefault()

        // ignore_notes is new (#103): the LC6000's idle heartbeat. layers and layer_note are new (#79): its four deck layers.
        #expect(mapping.midi == .init(
            input: "LC6000", output: "LC6000", channel: 1, ignoreNotes: [52],
            layers: [.init(channel: 1, deck: 1), .init(channel: 2, deck: 2), .init(channel: 3, deck: 3), .init(channel: 4, deck: 4)],
            layerNote: 51
        ))
        #expect(mapping.osc == .init(host: "127.0.0.1", port: 9090, root: "/Syndicate/", feedbackHost: "127.0.0.1", feedbackPort: 9096,
            feedbackQuietMs: 10000, feedbackAnswerMs: 2000
        ))
        #expect(mapping.deck.number == 1)
        // The jog as the hardware sends it (#103, captured 2026-11-15): a 14-bit position on CC 17/49. One slow full
        // turn measured about 3552 counts, so 3600; seek_seconds_per_rev and beats_per_rev are still PROVISIONAL.
        #expect(mapping.jog == .init(
            msbCC: 17, lsbCC: 49, countsPerRev: 3600, bendReleaseMs: 80, seekSecondsPerRev: 2.0, beatsPerRev: 4, requireTouch: false
        ))
        // pickup and pickup_tolerance are new in the app (#22): Python had no pickup.
        #expect(mapping.pitch == .init(msbCC: 8, lsbCC: 40, invert: false, deadZone: 0.005, pickup: true, pickupTolerance: 0.02))
        // shift_fader and its mode are new in the app (#609).
        #expect(mapping.needle == .init(msbCC: 64, lsbCC: 65, touchNote: 70, requireTouch: true, shiftFader: true, shiftFaderMode: .relative))
        #expect(mapping.browse == .init(selectTurnCC: 6, autoLoopSizeCC: 3))
        #expect(mapping.notes.buttons == [
            "play": 1, "cue": 2, "beat_jump_back": 3, "beat_jump_forward": 4, "track_prev": 5, "track_next": 6,
            "censor": 7, "loop_in": 8, "loop_out": 9, "auto_loop": 10, "back": 16, "forward": 17,
            "select_press": 18, "vinyl": 19, "sync": 20, "master": 21, "key_lock": 22, "deck_select": 23,
            "pitch_minus": 24, "pitch_plus": 25, "shift": 26, "mode_hotcue": 27, "mode_roll": 28,
            "mode_slicer": 29, "mode_loop": 30, "platter_touch": 40, "param_back": 68, "param_forward": 69,
        ])
        #expect(mapping.notes.pads == [32, 33, 34, 35, 36, 37, 38, 39])
        #expect(mapping.leds == .init(
            pitchCenter: 42, ring: 40, ringColor: [0, 128, 255], rollPadColor: [255, 140, 0],
            loopPadColor: [0, 255, 0], dimUnlitButtons: true, beatPulse: .off, pulseMs: 100, staleIdle: .dim,
            pitchArrowBack: 41, pitchArrowForward: 43, colorMessage: .init(notes: Array(32...40))
        ))
    }

    @Test("Deck select (#420) is a note 0-127; Slip, which the LC6000 no longer maps, is still a key other profiles may use")
    func deckSelectKey() {
        #expect(Mapping.problems(in: Data(#"{"notes": {"deck_select": 200}}"#.utf8)) == [
            "notes.deck_select: 200 is out of range, expected 0-127",
        ])
        #expect(Mapping.problems(in: Data(#"{"notes": {"slip": 99}}"#.utf8)) == [])
        #expect(Mapping.problems(in: Data(#"{"notes": {"slip": 200}}"#.utf8)) == [
            "notes.slip: 200 is out of range, expected 0-127",
        ])
    }

    @Test("A user override merges over the default like the Python config merge: tables deep, lists and values whole")
    func overrideMerges() throws {
        let override = Data("""
            {
              "deck": { "number": 2 },
              "notes": { "play": 11, "pads": [50, 51, 52, 53, 54, 55, 56, 57] },
              "jog": { "msb_cc": 18, "lsb_cc": 50 },
              "leds": { "ring_color": [255, 0, 0] }
            }
            """.utf8)

        let mapping = try Mapping.bundledDefault(overriddenBy: override)

        #expect(mapping.deck.number == 2)
        #expect(mapping.notes.buttons["play"] == 11)
        #expect(mapping.notes.buttons["cue"] == 2)
        #expect(mapping.notes.pads == [50, 51, 52, 53, 54, 55, 56, 57])
        #expect(mapping.jog?.msbCC == 18)
        #expect(mapping.jog?.lsbCC == 50)
        #expect(mapping.jog?.bendReleaseMs == 80)
        #expect(mapping.leds.ringColor == [255, 0, 0])
        #expect(mapping.leds.ring == 40)
        #expect(mapping.osc.port == 9090)
    }

    @Test("An override with a MIDI channel outside 1-16 is refused with a readable error, not a crash", arguments: [0, -1, 17, 300])
    func badChannelRefused(channel: Int) {
        let override = Data(#"{ "midi": { "channel": \#(channel) } }"#.utf8)
        #expect(throws: MappingError.invalid(["midi.channel: \(channel) is out of range, expected 1-16"])) {
            try Mapping.bundledDefault(overriddenBy: override)
        }
    }

    @Test("Channels 1 and 16 are accepted", arguments: [1, 16])
    func edgeChannelsAccepted(channel: Int) throws {
        let override = Data(#"{ "midi": { "channel": \#(channel) } }"#.utf8)
        #expect(try Mapping.bundledDefault(overriddenBy: override).midi.channel == channel)
    }

    @Test("An override's bad values and bad JSON come back as readable MappingErrors, never a raw decoder error (#92)")
    func overrideErrorsAreReadable() {
        #expect(throws: MappingError.invalid(["osc.feedback_quiet_ms: 1e+300 is out of range, expected 0-60000"])) {
            try Mapping.bundledDefault(overriddenBy: Data(#"{"osc": {"feedback_quiet_ms": 1e300}}"#.utf8))
        }
        #expect(throws: MappingError.invalid(["The file isn't valid JSON (near byte 1)."])) {
            try Mapping.bundledDefault(overriddenBy: Data("{".utf8))
        }
    }
}
