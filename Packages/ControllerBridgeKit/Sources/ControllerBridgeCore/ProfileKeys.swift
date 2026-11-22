import Foundation
// The profile key table (#382): every key a controller mapping takes, declared once. Its path (a list item's index
// written `[]`), its kind, the LC6000's value (ADR-0002: the LC6000 is the default), and its range, choices or list
// length. The checker and the decoder read it.

/// One mapping key.
public struct ProfileKey: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case wholeNumber, number, bool, text, list, object

        /// How a problem asks for it.
        public var words: String {
            switch self {
            case .wholeNumber: "a whole number"
            case .number: "a number"
            case .bool: "true or false"
            case .text: "text"
            case .list: "a list"
            case .object: "an object"
            }
        }
    }

    public let path: String
    public let kind: Kind
    /// The LC6000's value as JSON text; nil for a key the LC6000's mapping leaves out (an optional key).
    public let lc6000: String?
    public let range: ClosedRange<Double>?
    public let choices: [String]
    public let numberChoices: [Double]
    /// How many items a list takes, and what one is called in a problem ("value", "entry", "pad").
    public let count: ClosedRange<Int>?
    public let item: String
    /// What the decoder uses when the key is left out, as JSON text; nil when the decoder needs it, or has none.
    public let fallback: String?

    /// What's wrong with a list of `n` items, or nil when its length is fine.
    func countProblem(_ n: Int) -> String? {
        guard let count, !count.contains(n) else { return nil }
        if count.lowerBound == count.upperBound { return "expected \(count.lowerBound) \(item)s, got \(n)" }
        if count.upperBound == Int.max { return "expected at least one \(item)" }
        return "expected \(count.lowerBound)-\(count.upperBound) \(item)s, got \(n)"
    }

    init(_ path: String, _ kind: Kind, _ lc6000: String?, range: ClosedRange<Double>? = nil, choices: [String] = [],
         numberChoices: [Double] = [], count: ClosedRange<Int>? = nil, item: String = "value", fallback: String? = nil) {
        self.path = path
        self.kind = kind
        self.lc6000 = lc6000
        self.range = range
        self.choices = choices
        self.numberChoices = numberChoices
        self.count = count
        self.item = item
        self.fallback = fallback
    }
}

public enum ProfileKeys {
    /// Every key, in the LC6000's mapping's order, then the optional ones.
    public static let all: [ProfileKey] = lc6000Keys + optionalKeys

    /// The decoder's value for a left-out key, from the table (#382). The table tests pin every fallback, so a key
    /// without one, or one that doesn't decode, is a programming error.
    static func fallback<T: Decodable>(_ path: String, as type: T.Type = T.self) -> T {
        guard let text = key(path)?.fallback, let value = try? JSONDecoder().decode(T.self, from: Data(text.utf8)) else {
            preconditionFailure("The key table has no usable fallback for \(path)")
        }
        return value
    }

    /// The key at `path` (an index written as `[]`).
    public static func key(_ path: String) -> ProfileKey? { byPath[path] }
    private static let byPath = Dictionary(all.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

    static let note: ClosedRange<Double> = 0...127
    static let cc: ClosedRange<Double> = 0...127
    static let channel: ClosedRange<Double> = 1...16
    static let byte: ClosedRange<Double> = 0...255

    /// The buttons' notes, in the LC6000's order, with its values.
    static let buttons: [(String, Int)] = [
        ("play", 1), ("cue", 2), ("beat_jump_back", 3), ("beat_jump_forward", 4), ("track_prev", 5), ("track_next", 6),
        ("censor", 7), ("loop_in", 8), ("loop_out", 9), ("auto_loop", 10), ("back", 16), ("forward", 17),
        ("select_press", 18), ("vinyl", 19), ("sync", 20), ("master", 21), ("key_lock", 22), ("deck_select", 23),
        ("pitch_minus", 24), ("pitch_plus", 25), ("shift", 26), ("mode_hotcue", 27), ("mode_roll", 28),
        ("mode_slicer", 29), ("mode_loop", 30),
    ]
    static let mixerControls = ["volume", "trim", "eq_high", "eq_mid", "eq_low", "filter", "filter_res", "filter_width"]
    static let mixerNotes = ["cue_note", "mute_note", "solo_note"]
    static let padModes = ["hotcue", "roll", "loop", "slicer"]

    private static let lc6000Keys: [ProfileKey] = [
        ProfileKey("midi", .object, "{}"),
        ProfileKey("midi.input", .text, #""LC6000""#),
        ProfileKey("midi.output", .text, #""LC6000""#),
        ProfileKey("midi.channel", .wholeNumber, "1", range: channel),
        ProfileKey("midi.ignore_notes", .list, "[52]", fallback: "[]"),
        ProfileKey("midi.ignore_notes[]", .wholeNumber, "52", range: note),
        ProfileKey("midi.layers", .list, #"[{"channel": 1, "deck": 1}, {"channel": 2, "deck": 2}, {"channel": 3, "deck": 3}, {"channel": 4, "deck": 4}]"#, fallback: "[]"),
        ProfileKey("midi.layers[]", .object, "{}"),
        ProfileKey("midi.layers[].channel", .wholeNumber, "1", range: channel),
        ProfileKey("midi.layers[].deck", .wholeNumber, "1", range: 1...4),
        ProfileKey("midi.layer_note", .wholeNumber, "51", range: note),
        ProfileKey("midi.encoder_format", .text, #""twos_complement""#, choices: EncoderFormat.allRawValues, fallback: #""twos_complement""#),
        ProfileKey("osc", .object, "{}"),
        ProfileKey("osc.host", .text, #""127.0.0.1""#),
        ProfileKey("osc.port", .wholeNumber, "9090", range: 1...65535),
        ProfileKey("osc.root", .text, #""/Syndicate/""#),
        ProfileKey("osc.feedback_host", .text, #""127.0.0.1""#),
        ProfileKey("osc.feedback_port", .wholeNumber, "9096", range: 1...65535),
        ProfileKey("osc.feedback_quiet_ms", .wholeNumber, "10000", range: 0...60000),
        ProfileKey("osc.feedback_answer_ms", .wholeNumber, "2000", range: 0...60000),
        ProfileKey("deck", .object, "{}"),
        ProfileKey("deck.number", .wholeNumber, "1", range: 1...4),
        ProfileKey("jog", .object, "{}"),
        ProfileKey("jog.msb_cc", .wholeNumber, "17", range: cc),
        ProfileKey("jog.lsb_cc", .wholeNumber, "49", range: cc),
        ProfileKey("jog.counts_per_rev", .wholeNumber, "3600", range: 1...16384),
        ProfileKey("jog.bend_release_ms", .wholeNumber, "80", range: 1...5000),
        // Any number of seconds, 2.5 too (#399); the LC6000's 2.0 re-serializes as 2.
        ProfileKey("jog.seek_seconds_per_rev", .number, "2", range: 0...60),
        ProfileKey("jog.beats_per_rev", .wholeNumber, "4", range: 1...16),
        ProfileKey("jog.require_touch", .bool, "false"),
        ProfileKey("pitch", .object, "{}"),
        ProfileKey("pitch.bits", .wholeNumber, "14", numberChoices: [7, 14], fallback: "14"),
        ProfileKey("pitch.msb_cc", .wholeNumber, "8", range: cc),
        ProfileKey("pitch.lsb_cc", .wholeNumber, "40", range: cc),
        ProfileKey("pitch.invert", .bool, "false"),
        ProfileKey("pitch.dead_zone", .number, "0.005", range: 0...1),
        ProfileKey("pitch.pickup", .bool, "true", fallback: "true"),
        ProfileKey("pitch.pickup_tolerance", .number, "0.02", range: 0...1, fallback: "0.02"),
        ProfileKey("needle", .object, "{}"),
        ProfileKey("needle.msb_cc", .wholeNumber, "64", range: cc),
        ProfileKey("needle.lsb_cc", .wholeNumber, "65", range: cc),
        ProfileKey("needle.touch_note", .wholeNumber, "70", range: note),
        ProfileKey("needle.require_touch", .bool, "true"),
        ProfileKey("needle.shift_fader", .bool, "true", fallback: "false"),
        ProfileKey("needle.shift_fader_mode", .text, #""relative""#, choices: Mapping.Needle.ShiftFaderMode.allRawValues,
                   fallback: #""relative""#),
        ProfileKey("browse", .object, "{}"),
        ProfileKey("browse.select_turn_cc", .wholeNumber, "6", range: cc),
        ProfileKey("browse.auto_loop_size_cc", .wholeNumber, "3", range: cc),
        ProfileKey("notes", .object, "{}"),
    ] + buttons.map { ProfileKey("notes.\($0.0)", .wholeNumber, "\($0.1)", range: note) } + [
        ProfileKey("notes.pads", .list, "[32, 33, 34, 35, 36, 37, 38, 39]", count: 1...16, item: "pad"),
        ProfileKey("notes.pads[]", .wholeNumber, "32", range: note),
        ProfileKey("notes.platter_touch", .wholeNumber, "40", range: note),
        ProfileKey("notes.param_back", .wholeNumber, "68", range: note),
        ProfileKey("notes.param_forward", .wholeNumber, "69", range: note),
        ProfileKey("leds", .object, "{}"),
        ProfileKey("leds.pitch_center", .wholeNumber, "42", range: note),
        ProfileKey("leds.pitch_arrow_back", .wholeNumber, "41", range: note),
        ProfileKey("leds.pitch_arrow_forward", .wholeNumber, "43", range: note),
        ProfileKey("leds.ring", .wholeNumber, "40", range: note),
        ProfileKey("leds.ring_color", .list, "[0, 128, 255]", count: 3...3),
        ProfileKey("leds.ring_color[]", .wholeNumber, "0", range: byte),
        ProfileKey("leds.ring_follows_deck", .bool, "true", fallback: "true"),
        ProfileKey("leds.roll_pad_color", .list, "[255, 140, 0]", count: 3...3),
        ProfileKey("leds.roll_pad_color[]", .wholeNumber, "255", range: byte),
        ProfileKey("leds.loop_pad_color", .list, "[0, 255, 0]", count: 3...3),
        ProfileKey("leds.loop_pad_color[]", .wholeNumber, "0", range: byte),
        ProfileKey("leds.dim_unlit_buttons", .bool, "true"),
        ProfileKey("leds.mirror_shifted", .bool, "false", fallback: "false"),
        ProfileKey("leds.beat_pulse", .text, #""off""#, choices: Mapping.LEDs.BeatPulse.allRawValues),
        ProfileKey("leds.pulse_ms", .wholeNumber, "100", range: 0...60000),
        ProfileKey("leds.stale_idle", .text, #""dim""#, choices: Mapping.LEDs.StaleIdle.allRawValues),
        ProfileKey("leds.levels", .object, "{}"),
        ProfileKey("leds.levels.full", .wholeNumber, "127", range: note, fallback: "127"),
        ProfileKey("leds.levels.dim", .wholeNumber, "1", range: note, fallback: "1"),
        ProfileKey("leds.levels.off", .wholeNumber, "0", range: note, fallback: "0"),
        // "rgb222", or a list of entries (#197): the list form is its own keys below.
        ProfileKey("leds.color_table", .text, #""rgb222""#, choices: ["rgb222"], count: 1...Int.max, item: "entry", fallback: #""rgb222""#),
        // Denon's color message (#530): the LEDs that take exact RGB. Left out, a controller has none.
        ProfileKey("leds.color_message", .object, "{}"),
        ProfileKey("leds.color_message.notes", .list, "[32, 33, 34, 35, 36, 37, 38, 39, 40]", count: 1...Int.max, item: "note"),
        ProfileKey("leds.color_message.notes[]", .wholeNumber, "32", range: note),
        ProfileKey("pads", .object, "{}"),
        ProfileKey("pads.roll_sizes", .list, #"["ThirtySecond", "Sixteenth", "Eighth", "Quarter", "Half", "One", "Two", "Four"]"#, fallback: #"["ThirtySecond", "Sixteenth", "Eighth", "Quarter", "Half", "One", "Two", "Four"]"#),
        ProfileKey("pads.roll_sizes[]", .text, #""ThirtySecond""#, choices: Mapping.Pads.RollSize.allRawValues),
        ProfileKey("pads.mode_select", .text, #""buttons""#, choices: Mapping.Pads.ModeSelect.allRawValues, fallback: #""buttons""#),
    ]

    private static let optionalKeys: [ProfileKey] = [
        // The color table as a list of entries (#197).
        ProfileKey("leds.color_table[]", .object, nil),
        ProfileKey("leds.color_table[].rgb", .list, nil, count: 3...3),
        ProfileKey("leds.color_table[].rgb[]", .wholeNumber, nil, range: byte),
        ProfileKey("leds.color_table[].value", .wholeNumber, nil, range: note),
        // A relative jog (#204).
        ProfileKey("jog.relative_cc", .wholeNumber, nil, range: cc),
        ProfileKey("jog.relative_edge_cc", .wholeNumber, nil, range: cc),
        // Slip, which the LC6000 maps to deck select instead (#420).
        ProfileKey("notes.slip", .wholeNumber, nil, range: note),
        // One cycling pad-mode button (#198), and its LED's velocity per mode.
        ProfileKey("notes.mode_cycle", .wholeNumber, nil, range: note),
        ProfileKey("pads.mode_cycle_velocities", .object, nil),
    ] + padModes.map { ProfileKey("pads.mode_cycle_velocities.\($0)", .wholeNumber, nil, range: note) } + [
        // The pads' own channel (#224), and with Shift held (#324), for the deck and for each layer.
        ProfileKey("pads.channel", .wholeNumber, nil, range: channel),
        ProfileKey("midi.layers[].pad_channel", .wholeNumber, nil, range: channel),
        ProfileKey("pads.shifted_channel", .wholeNumber, nil, range: channel),
        ProfileKey("midi.layers[].shifted_pad_channel", .wholeNumber, nil, range: channel),
        // Each pad mode's own notes (#225).
        ProfileKey("pads.mode_notes", .object, nil),
    ] + padModes.flatMap { [
        ProfileKey("pads.mode_notes.\($0)", .list, nil),
        ProfileKey("pads.mode_notes.\($0)[]", .wholeNumber, nil, range: note),
    ] } + [
        // Shift done in hardware (#226): a button's own note with Shift held.
        ProfileKey("notes.shifted", .object, nil, fallback: "{}"),
    ] + (buttons.map(\.0) + ["slip", "platter_touch", "param_back", "param_forward"]).map {
        ProfileKey("notes.shifted.\($0)", .wholeNumber, nil, range: note)
    } + [
        // The mixer (#207): the LC6000 has none.
        ProfileKey("mixer", .object, nil),
    ] + mixerControls.flatMap { [
        ProfileKey("mixer.\($0)", .object, nil),
        ProfileKey("mixer.\($0).msb_cc", .wholeNumber, nil, range: cc),
        ProfileKey("mixer.\($0).lsb_cc", .wholeNumber, nil, range: cc),
        ProfileKey("mixer.\($0).bits", .wholeNumber, nil, numberChoices: [7, 14], fallback: "14"),
    ] } + mixerNotes.map { ProfileKey("mixer.\($0)", .wholeNumber, nil, range: note) } + [
        ProfileKey("mixer.meter", .object, nil),
        ProfileKey("mixer.meter.cc", .wholeNumber, nil, range: cc),
        ProfileKey("mixer.meter.steps", .list, nil, count: 1...Int.max),
        ProfileKey("mixer.meter.steps[]", .wholeNumber, nil, range: note),
        ProfileKey("mixer.meter.clip", .wholeNumber, nil, range: note),
        ProfileKey("mixer.meter.hold_ms", .wholeNumber, nil, range: 0...10000, fallback: "300"),
        ProfileKey("mixer.meter.rate_hz", .wholeNumber, nil, range: 1...120, fallback: "30"),
        ProfileKey("mixer.pickup", .bool, nil, fallback: "true"),
        ProfileKey("mixer.pickup_tolerance", .number, nil, range: 0...1, fallback: "0.02"),
    ]
}
