import ControllerBridgeCore
import Foundation
import Testing

/// The full mapping check (#24): every problem in a mapping body, by key path, in document order. The bundled
/// default mapping is the schema. Bodies here are partial overrides, as a user's import is.
@Suite("Mapping check")
struct MappingCheckTests {
    static func problems(_ json: String) -> [String] {
        Mapping.problems(in: Data(json.utf8))
    }

    @Test("A key the default mapping doesn't have is unknown, named by its path; a typo isn't silently a new button")
    func unknownKeys() {
        #expect(Self.problems(#"{"notes": {"paly": 1}}"#) == ["notes.paly: unknown key"])
        #expect(Self.problems(#"{"lights": {}, "deck": {"number": 2, "side": "left"}}"#) == [
            "lights: unknown key",
            "deck.side: unknown key",
        ])
    }

    @Test("The default mapping itself has no problems")
    func defaultIsClean() throws {
        #expect(Mapping.problems(in: try Mapping.defaultMappingJSON()) == [])
    }

    @Test("A value of the wrong kind names what was expected and what was found")
    func wrongTypes() {
        #expect(Self.problems(#"{"pitch": {"invert": 1}}"#) == ["pitch.invert: expected true or false, got 1"])
        #expect(Self.problems(#"{"midi": {"channel": 1.5, "input": 5}}"#) == [
            "midi.channel: expected a whole number, got 1.5",
            "midi.input: expected text, got 5",
        ])
        #expect(Self.problems(#"{"jog": {"msb_cc": [17], "dead": 1}, "pitch": {"dead_zone": "small"}}"#) == [
            "jog.msb_cc: expected a whole number, got a list",
            "jog.dead: unknown key",
            "pitch.dead_zone: expected a number, got \"small\"",
        ])
        #expect(Self.problems(#"{"notes": {"pads": [32, "x", 34, 35, 36, 37, 38, 39]}, "deck": 2}"#) == [
            "notes.pads[1]: expected a whole number, got \"x\"",
            "deck: expected an object, got 2",
        ])
    }

    @Test("A whole number written as 2.0 is still a whole number; a fractional setting accepts a whole number")
    func numberForms() {
        #expect(Self.problems(#"{"deck": {"number": 2.0}, "pitch": {"dead_zone": 0}}"#) == [])
    }

    @Test("Notes and CCs are 0–127, including pads, jog CCs and LED notes")
    func midiRanges() {
        #expect(Self.problems(#"{"notes": {"play": 128, "pads": [32, -1, 34, 35, 36, 37, 38, 39]}, "jog": {"lsb_cc": 200}, "leds": {"ring": 300}}"#) == [
            "notes.play: 128 is out of range, expected 0-127",
            "notes.pads[1]: -1 is out of range, expected 0-127",
            "jog.lsb_cc: 200 is out of range, expected 0-127",
            "leds.ring: 300 is out of range, expected 0-127",
        ])
        #expect(Self.problems(#"{"pitch": {"msb_cc": 128}, "needle": {"touch_note": 999}, "browse": {"select_turn_cc": -5}}"#) == [
            "pitch.msb_cc: 128 is out of range, expected 0-127",
            "needle.touch_note: 999 is out of range, expected 0-127",
            "browse.select_turn_cc: -5 is out of range, expected 0-127",
        ])
    }

    @Test("Channel is 1–16 and deck 1–4")
    func channelAndDeck() {
        #expect(Self.problems(#"{"midi": {"channel": 0}, "deck": {"number": 5}}"#) == [
            "midi.channel: 0 is out of range, expected 1-16",
            "deck.number: 5 is out of range, expected 1-4",
        ])
    }

    @Test("A color is exactly 3 values, each 0–255")
    func colors() {
        #expect(Self.problems(#"{"leds": {"ring_color": [0, 128], "roll_pad_color": [255, 256, 0]}}"#) == [
            "leds.ring_color: expected 3 values, got 2",
            "leds.roll_pad_color[1]: 256 is out of range, expected 0-255",
        ])
    }

    @Test("A choice must be one of its values")
    func choices() {
        #expect(Self.problems(#"{"leds": {"beat_pulse": "bar", "stale_idle": "dark"}}"#) == [
            "leds.beat_pulse: \"bar\" isn't one of off, beat, downbeat",
            "leds.stale_idle: \"dark\" isn't one of dim, off",
        ])
    }

    @Test("A note used twice is named where the user wrote it, with the other use; defaults count too")
    func duplicateNotes() {
        // The default has cue = 2.
        #expect(Self.problems(#"{"notes": {"play": 2}}"#) == ["notes.play: note 2 is also notes.cue"])
        #expect(Self.problems(#"{"notes": {"pads": [32, 33, 34, 35, 36, 37, 38, 1]}}"#) == ["notes.pads[7]: note 1 is also notes.play"])
        // Needle touch is a note too.
        #expect(Self.problems(#"{"needle": {"touch_note": 21}}"#) == ["needle.touch_note: note 21 is also notes.master"])
    }

    @Test("A CC used by two features is a duplicate, including the jog's and the strip's 14-bit pairs (#103)")
    func duplicateCCs() {
        #expect(Self.problems(#"{"needle": {"msb_cc": 8}}"#) == ["needle.msb_cc: CC 8 is also pitch.msb_cc"])
        #expect(Self.problems(#"{"jog": {"lsb_cc": 17}}"#) == ["jog.lsb_cc: CC 17 is also jog.msb_cc"])
        #expect(Self.problems(#"{"jog": {"msb_cc": 18, "lsb_cc": 50}}"#) == [])
    }

    @Test("Notes, CCs and LED notes are separate: the same number in two of them is fine")
    func namespaces() {
        // platter_touch = 40 (note), pitch.lsb_cc = 40 (CC) and leds.ring = 40 (LED) all ship in the default.
        #expect(Self.problems(#"{"notes": {"platter_touch": 40}, "pitch": {"lsb_cc": 40}, "leds": {"ring": 40}}"#) == [])
    }

    @Test("Every problem is listed at once, in the order the user wrote them")
    func allAtOnceInOrder() {
        #expect(Self.problems(#"{"notes": {"play": 2, "paly": 1}, "midi": {"channel": 20}, "leds": {"beat_pulse": "bar"}}"#) == [
            "notes.play: note 2 is also notes.cue",
            "notes.paly: unknown key",
            "midi.channel: 20 is out of range, expected 1-16",
            "leds.beat_pulse: \"bar\" isn't one of off, beat, downbeat",
        ])
    }

    @Test("A file that isn't JSON, or isn't an object, is one plain problem")
    func notAMapping() {
        // 20 bytes, cut off mid-object: the reader runs out at byte 20.
        #expect(Self.problems(#"{"notes": {"play": 1"#) == ["The file isn't valid JSON (near byte 20)."])
        #expect(Self.problems(#"[1, 2]"#) == ["mapping: expected an object, got a list"])
    }

    // MARK: Files that once crashed the app (#92). An imported file is untrusted.

    @Test("A file nested 100 000 deep is refused with one readable problem, instead of overflowing the stack")
    func deepNesting() {
        let deep = #"{"x": "# + String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000) + "}"
        #expect(Self.problems(deep) == ["The file nests deeper than 64 levels, so it isn't a mapping."])
    }

    @Test("A controller has 1 to 16 pads (#196): 17, or none, is refused; 4 and 16 are fine")
    func padCount() {
        #expect(Self.problems(#"{"notes": {"pads": [\#((100...116).map(String.init).joined(separator: ", "))]}}"#) == ["notes.pads: expected 1-16 pads, got 17"])
        #expect(Self.problems(#"{"notes": {"pads": []}}"#) == ["notes.pads: expected 1-16 pads, got 0"])
        #expect(Self.problems(#"{"notes": {"pads": [32, 33, 34, 35]}}"#) == [])
    }

    @Test("The jog's turn scaling must be usable: at least 1 count and 1 beat a turn, so nothing divides by zero")
    func ticksPerBeat() {
        #expect(Self.problems(#"{"jog": {"counts_per_rev": 0, "beats_per_rev": 0, "seek_seconds_per_rev": 61}}"#) == [
            "jog.counts_per_rev: 0 is out of range, expected 1-16384",
            "jog.beats_per_rev: 0 is out of range, expected 1-16",
            "jog.seek_seconds_per_rev: 61 is out of range, expected 0-60",
        ])
    }

    @Test("Seconds per turn may be fractional (#399): 2.5 passes the check and decodes as 2.5")
    func fractionalSeekSeconds() throws {
        #expect(Self.problems(#"{"jog": {"seek_seconds_per_rev": 2.5}}"#) == [])
        var body = try JSONSerialization.jsonObject(with: Mapping.defaultMappingJSON()) as! [String: Any]
        var jog = body["jog"] as! [String: Any]
        jog["seek_seconds_per_rev"] = 2.5
        body["jog"] = jog
        let mapping = try JSONDecoder().decode(Mapping.self, from: JSONSerialization.data(withJSONObject: body))
        #expect(mapping.jog?.seekSecondsPerRev == 2.5)
    }

    @Test("Every other number has a range too: a port past 65535, a negative time and a huge time are named")
    func numberRanges() {
        #expect(Self.problems(#"{"osc": {"port": 70000, "feedback_port": 0, "feedback_quiet_ms": -5, "feedback_answer_ms": 1e300}}"#) == [
            "osc.port: 70000 is out of range, expected 1-65535",
            "osc.feedback_port: 0 is out of range, expected 1-65535",
            "osc.feedback_quiet_ms: -5 is out of range, expected 0-60000",
            "osc.feedback_answer_ms: 1e+300 is out of range, expected 0-60000",
        ])
        #expect(Self.problems(#"{"jog": {"bend_release_ms": 0}, "pitch": {"dead_zone": 2, "pickup_tolerance": -1}, "leds": {"pulse_ms": 99999}}"#) == [
            "jog.bend_release_ms: 0 is out of range, expected 1-5000",
            "pitch.dead_zone: 2 is out of range, expected 0-1",
            "pitch.pickup_tolerance: -1 is out of range, expected 0-1",
            "leds.pulse_ms: 99999 is out of range, expected 0-60000",
        ])
    }

    @Test("A number too big to be a real number (1e999 is infinity) is refused where the user wrote it")
    func infiniteNumber() {
        #expect(Self.problems(#"{"pitch": {"dead_zone": 1e999}}"#) == ["The file has a number too large to use (near byte 24)."])
    }

    @Test("The mixer section (#207) is checked like the rest: kinds, ranges, bits, unknown keys and CC or note clashes")
    func mixer() {
        #expect(Self.problems(MixerTests.section) == [])
        #expect(Self.problems(#"{"mixer": {"volume": {"msb_cc": 200, "bits": 8}, "fader": 1}}"#) == [
            "mixer.volume.msb_cc: 200 is out of range, expected 0-127",
            "mixer.volume.bits: 8 isn't one of 7, 14",
            "mixer.fader: unknown key",
        ])
        #expect(Self.problems(#"{"mixer": {"meter": {"cc": 2, "steps": []}}}"#) == ["mixer.meter.steps: expected at least one value"])
        #expect(Self.problems(#"{"mixer": {"meter": {"cc": 2, "steps": [0, 300]}}}"#) == [
            "mixer.meter.steps[1]: 300 is out of range, expected 0-127",
        ])
        #expect(Self.problems(#"{"mixer": {"volume": {"msb_cc": 17, "bits": 7}}}"#) == ["mixer.volume.msb_cc: CC 17 is also jog.msb_cc"])
        #expect(Self.problems(#"{"mixer": {"cue_note": 2}}"#) == ["mixer.cue_note: note 2 is also notes.cue"])
    }
}
