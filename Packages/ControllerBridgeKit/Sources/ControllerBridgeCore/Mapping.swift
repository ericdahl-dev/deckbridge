import Foundation

/// The LC6000 mapping: note and CC numbers, OSC settings and LED colors.
///
/// The bundled default is ported value for value from the Python bridge's default_mapping.toml (removed in #30), with the same
/// section and key names. Note and CC numbers come from Denon's "LC6000 PRIME MIDI Specification v1.0" and were
/// checked on a real unit (2026-11-15, #12, #103). What's still PROVISIONAL is listed in the Kit README.
public struct Mapping: Equatable, Sendable, Codable {
    public var midi: MIDI
    public var osc: OSC
    public var deck: Deck
    /// The jog wheel; nil on a controller without one (#341).
    public var jog: Jog?
    /// The pitch fader; nil on a controller without one (#341).
    public var pitch: Pitch?
    /// The Needle Drop strip; nil on a controller without one (#341).
    public var needle: Needle?
    /// The browse knob; nil on a controller without one (#341).
    public var browse: Browse?
    public var notes: Notes
    public var leds: LEDs
    /// What the pads play beyond their notes (#196): the roll each pad plays in Roll mode.
    public var pads: Pads
    /// The mixer section (#207), for controllers that have one. Nil on the LC6000.
    public var mixer: Mixer?

    enum CodingKeys: String, CodingKey {
        case midi, osc, deck, jog, pitch, needle, browse, notes, leds, pads, mixer
    }

    /// `pads` may be left out: the LC6000's roll sizes.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        midi = try c.decode(MIDI.self, forKey: .midi)
        osc = try c.decode(OSC.self, forKey: .osc)
        deck = try c.decode(Deck.self, forKey: .deck)
        jog = try c.decodeIfPresent(Jog.self, forKey: .jog)
        pitch = try c.decodeIfPresent(Pitch.self, forKey: .pitch)
        needle = try c.decodeIfPresent(Needle.self, forKey: .needle)
        browse = try c.decodeIfPresent(Browse.self, forKey: .browse)
        notes = try c.decode(Notes.self, forKey: .notes)
        leds = try c.decode(LEDs.self, forKey: .leds)
        pads = try c.decodeIfPresent(Pads.self, forKey: .pads) ?? Pads()
        mixer = try c.decodeIfPresent(Mixer.self, forKey: .mixer)
        if pads.modeSelect == .cycle, notes.buttons["mode_cycle"] == nil {
            throw ShapeError("pads: mode_select is cycle, but notes has no mode_cycle button")
        }
        // Notes per pad mode (#225): one note per pad in every mode.
        for (name, notes) in pads.modeNotes?.named ?? [] where notes.count != self.notes.pads.count {
            throw ShapeError("pads.mode_notes.\(name): \(notes.count) notes, but there are \(self.notes.pads.count) pads (notes.pads)")
        }
    }

    /// The pads' Roll mode (#196): pad N plays `rollSizes[N - 1]`, by Syndicate's SlipLoop names. A pad past the list
    /// does nothing in Roll mode.
    public struct Pads: Equatable, Sendable, Codable {
        /// Syndicate's slip loop sizes, shortest first.
        public enum RollSize: String, CaseIterable, Equatable, Sendable, Codable {
            case thirtySecond = "ThirtySecond", sixteenth = "Sixteenth", eighth = "Eighth", quarter = "Quarter"
            case half = "Half", one = "One", two = "Two", four = "Four"
        }

        public var rollSizes: [String]
        /// The MIDI channel (1-16) the pads use (#224), when not the deck's: the DDJ-400/FLX4's deck 1 pads are on 8.
        /// Left out (the LC6000), the pads are on the deck's channel.
        public var channel: Int?

        /// Each pad mode's own notes, one per pad (#225), on controllers whose pads send a different note range per
        /// mode, as Pioneer's do. Left out (the LC6000), `notes.pads` serves every mode and DeckBridge tracks the mode.
        public struct ModeNotes: Equatable, Sendable, Codable {
            public var hotcue: [Int]
            public var roll: [Int]
            public var loop: [Int]
            public var slicer: [Int]

            public init(hotcue: [Int], roll: [Int], loop: [Int], slicer: [Int]) {
                self.hotcue = hotcue
                self.roll = roll
                self.loop = loop
                self.slicer = slicer
            }
            enum CodingKeys: String, CodingKey, CaseIterable { case hotcue, roll, loop, slicer }

            /// All four modes are listed; one left out is named.
            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                func list(_ key: CodingKeys) throws -> [Int] {
                    guard let notes = try c.decodeIfPresent([Int].self, forKey: key) else {
                        throw ShapeError("pads.mode_notes: \(key.rawValue) is missing (list all four modes)")
                    }
                    return notes
                }
                hotcue = try list(.hotcue)
                roll = try list(.roll)
                loop = try list(.loop)
                slicer = try list(.slicer)
            }

            /// Each mode's list with its name, in mode order.
            var named: [(String, [Int])] { [("hotcue", hotcue), ("roll", roll), ("loop", loop), ("slicer", slicer)] }
        }

        public var modeNotes: ModeNotes?
        /// The channel the pads send on with Shift held (#324), when the hardware does Shift itself: the DDJ-400's
        /// deck 1 Shift pads are on 9. A pad on it is that pad with Shift.
        public var shiftedChannel: Int?

        /// How the pad mode is chosen (#198): the LC6000's four mode buttons, or one button that cycles them.
        public enum ModeSelect: String, CaseIterable, Equatable, Sendable, Codable {
            /// `mode_hotcue`, `mode_roll`, `mode_loop` and `mode_slicer`, one per mode.
            case buttons
            /// One `mode_cycle` button: Hot Cue → Roll → Loop → Slicer → Hot Cue.
            case cycle
        }

        public var modeSelect: ModeSelect

        /// The velocity the `mode_cycle` button's own LED shows in each mode (#198), when it has one: a level or a
        /// color, as the controller reads it. Left out, DeckBridge leaves that LED alone.
        public struct ModeVelocities: Equatable, Sendable, Codable {
            public var hotcue: Int
            public var roll: Int
            public var loop: Int
            public var slicer: Int

            public init(hotcue: Int, roll: Int, loop: Int, slicer: Int) {
                self.hotcue = hotcue
                self.roll = roll
                self.loop = loop
                self.slicer = slicer
            }
        }

        public var modeCycleVelocities: ModeVelocities?

        /// The LC6000's: 1/32 of a beat on pad 1 up to 4 beats on pad 8.
        public static let lc6000RollSizes: [String] = ProfileKeys.fallback("pads.roll_sizes")

        public init(rollSizes: [String] = Self.lc6000RollSizes, modeSelect: ModeSelect = .buttons,
                    modeCycleVelocities: ModeVelocities? = nil) {
            self.rollSizes = rollSizes
            self.modeSelect = modeSelect
            self.modeCycleVelocities = modeCycleVelocities
        }

        enum CodingKeys: String, CodingKey {
            case rollSizes = "roll_sizes", channel, modeNotes = "mode_notes", shiftedChannel = "shifted_channel"
            case modeSelect = "mode_select", modeCycleVelocities = "mode_cycle_velocities"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rollSizes = try c.decodeIfPresent([String].self, forKey: .rollSizes) ?? ProfileKeys.fallback("pads.roll_sizes")
            modeSelect = try c.decodeIfPresent(ModeSelect.self, forKey: .modeSelect) ?? ProfileKeys.fallback("pads.mode_select")
            modeCycleVelocities = try c.decodeIfPresent(ModeVelocities.self, forKey: .modeCycleVelocities)
            channel = try c.decodeIfPresent(Int.self, forKey: .channel)
            modeNotes = try c.decodeIfPresent(ModeNotes.self, forKey: .modeNotes)
            shiftedChannel = try c.decodeIfPresent(Int.self, forKey: .shiftedChannel)
        }
    }

    public struct MIDI: Equatable, Sendable, Codable {
        public var input: String
        public var output: String
        /// 1-16.
        public var channel: Int
        /// Notes the controller sends on its own, such as the LC6000's idle heartbeat on note 52 (#103): dropped
        /// before anything sees them.
        public var ignoreNotes: [Int]
        /// The controller's own deck layers (#79): each MIDI channel drives a Syndicate deck. Empty for a controller
        /// without layers.
        public var layers: [Layer]
        /// The note the controller sends on a layer's channel as it becomes active (127) or inactive (0).
        public var layerNote: Int?
        /// How the relative encoders write a turn (#193): two's complement, the LC6000's, unless the profile says.
        public var encoderFormat: EncoderFormat

        enum CodingKeys: String, CodingKey {
            case input, output, channel, layers
            case ignoreNotes = "ignore_notes"
            case layerNote = "layer_note"
            case encoderFormat = "encoder_format"
        }

        public init(
            input: String, output: String, channel: Int, ignoreNotes: [Int] = [], layers: [Layer] = [], layerNote: Int? = nil,
            encoderFormat: EncoderFormat = .twosComplement
        ) {
            self.input = input
            self.output = output
            self.channel = channel
            self.ignoreNotes = ignoreNotes
            self.layers = layers
            self.layerNote = layerNote
            self.encoderFormat = encoderFormat
        }

        /// `ignore_notes`, `layers`, `layer_note` and `encoder_format` may be left out: nothing ignored, no layers, two's
        /// complement.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            input = try container.decode(String.self, forKey: .input)
            output = try container.decode(String.self, forKey: .output)
            channel = try container.decode(Int.self, forKey: .channel)
            ignoreNotes = try container.decodeIfPresent([Int].self, forKey: .ignoreNotes) ?? ProfileKeys.fallback("midi.ignore_notes")
            layers = try container.decodeIfPresent([Layer].self, forKey: .layers) ?? ProfileKeys.fallback("midi.layers")
            layerNote = try container.decodeIfPresent(Int.self, forKey: .layerNote)
            encoderFormat = try container.decodeIfPresent(EncoderFormat.self, forKey: .encoderFormat) ?? ProfileKeys.fallback("midi.encoder_format")
        }
    }

    /// One of a controller's deck layers: its MIDI channel, 1-16, and the Syndicate deck it drives, 1-4.
    public struct Layer: Equatable, Sendable, Codable {
        public var channel: Int
        public var deck: Int
        /// The channel this layer's pads use (#224), when not `channel`: the DDJ-400/FLX4's deck 2 pads are on 10.
        public var padChannel: Int?
        /// The channel this layer's pads send on with Shift held (#324): the DDJ-400's deck 2 Shift pads are on 11.
        public var shiftedPadChannel: Int?

        enum CodingKeys: String, CodingKey {
            case channel, deck
            case padChannel = "pad_channel", shiftedPadChannel = "shifted_pad_channel"
        }

        public init(channel: Int, deck: Int, padChannel: Int? = nil, shiftedPadChannel: Int? = nil) {
            self.channel = channel
            self.deck = deck
            self.padChannel = padChannel
            self.shiftedPadChannel = shiftedPadChannel
        }
    }

    public struct OSC: Equatable, Sendable, Codable {
        public var host: String
        public var port: Int
        public var root: String
        public var feedbackHost: String
        public var feedbackPort: Int
        /// After this long with no feedback, the bridge asks Syndicate to resend, to tell a quiet Syndicate from a
        /// gone one. Syndicate sends nothing while every deck is paused and nothing changes.
        public var feedbackQuietMs: Int
        /// How long that request may go unanswered before feedback counts as stopped.
        public var feedbackAnswerMs: Int

        enum CodingKeys: String, CodingKey {
            case host, port, root
            case feedbackHost = "feedback_host"
            case feedbackPort = "feedback_port"
            case feedbackQuietMs = "feedback_quiet_ms"
            case feedbackAnswerMs = "feedback_answer_ms"
        }

        public init(
            host: String, port: Int, root: String, feedbackHost: String, feedbackPort: Int,
            feedbackQuietMs: Int, feedbackAnswerMs: Int
        ) {
            self.host = host
            self.port = port
            self.root = root
            self.feedbackHost = feedbackHost
            self.feedbackPort = feedbackPort
            self.feedbackQuietMs = feedbackQuietMs
            self.feedbackAnswerMs = feedbackAnswerMs
        }
    }

    public struct Deck: Equatable, Sendable, Codable {
        /// The Syndicate deck, 1-4.
        public var number: Int

        public init(number: Int) { self.number = number }
    }

    /// The jog wheel. The LC6000's sends a 14-bit platter position that counts up going forward and wraps at 16384
    /// (#103): movement is the change in position. A relative jog (#204) sends ticks on one CC instead, in the
    /// profile's encoder format. Either way movement is scaled per platter revolution.
    public struct Jog: Equatable, Sendable, Codable {
        /// How the platter reports movement.
        public enum Mode: Equatable, Sendable {
            case absolute(msbCC: Int, lsbCC: Int)
            /// Ticks on `cc` (the platter's top). `edgeCC`, if the controller has one, is the platter's edge, which
            /// moves without a touch.
            case relative(cc: Int, edgeCC: Int?)
        }

        public var msbCC: Int?
        public var lsbCC: Int?
        /// A relative jog's CC (#204). When set, the jog is relative and the 14-bit pair may be left out.
        public var relativeCC: Int?
        /// A relative jog's edge CC, which needs no touch (#204).
        public var relativeEdgeCC: Int?
        /// Counts in one full platter turn: about 3552 position counts measured on the LC6000 (#103), so 3600. For a
        /// relative jog, ticks per turn.
        public var countsPerRev: Int
        public var bendReleaseMs: Int
        /// While paused, how far one platter turn moves the playhead.
        public var seekSecondsPerRev: Double
        /// While paused with no track length, how many beats one platter turn skips.
        public var beatsPerRev: Double
        public var requireTouch: Bool

        public var mode: Mode {
            if let relativeCC { return .relative(cc: relativeCC, edgeCC: relativeEdgeCC) }
            return .absolute(msbCC: msbCC ?? 0, lsbCC: lsbCC ?? 0)
        }

        enum CodingKeys: String, CodingKey {
            case msbCC = "msb_cc"
            case lsbCC = "lsb_cc"
            case relativeCC = "relative_cc"
            case relativeEdgeCC = "relative_edge_cc"
            case countsPerRev = "counts_per_rev"
            case bendReleaseMs = "bend_release_ms"
            case seekSecondsPerRev = "seek_seconds_per_rev"
            case beatsPerRev = "beats_per_rev"
            case requireTouch = "require_touch"
        }

        /// A jog needs its 14-bit pair or a relative CC; either is enough (#204).
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            msbCC = try c.decodeIfPresent(Int.self, forKey: .msbCC)
            lsbCC = try c.decodeIfPresent(Int.self, forKey: .lsbCC)
            relativeCC = try c.decodeIfPresent(Int.self, forKey: .relativeCC)
            relativeEdgeCC = try c.decodeIfPresent(Int.self, forKey: .relativeEdgeCC)
            countsPerRev = try c.decode(Int.self, forKey: .countsPerRev)
            bendReleaseMs = try c.decode(Int.self, forKey: .bendReleaseMs)
            seekSecondsPerRev = try c.decode(Double.self, forKey: .seekSecondsPerRev)
            beatsPerRev = try c.decode(Double.self, forKey: .beatsPerRev)
            requireTouch = try c.decode(Bool.self, forKey: .requireTouch)
            guard relativeCC == nil else { return }
            switch (msbCC, lsbCC) {
            case (nil, nil): throw JogError.needsPairOrRelative
            case (nil, _): throw JogError.missing("msb_cc")
            case (_, nil): throw JogError.missing("lsb_cc")
            default: break
            }
        }

        public init(
            msbCC: Int?, lsbCC: Int?, countsPerRev: Int, bendReleaseMs: Int, seekSecondsPerRev: Double, beatsPerRev: Double,
            requireTouch: Bool, relativeCC: Int? = nil, relativeEdgeCC: Int? = nil
        ) {
            self.msbCC = msbCC
            self.lsbCC = lsbCC
            self.relativeCC = relativeCC
            self.relativeEdgeCC = relativeEdgeCC
            self.countsPerRev = countsPerRev
            self.bendReleaseMs = bendReleaseMs
            self.seekSecondsPerRev = seekSecondsPerRev
            self.beatsPerRev = beatsPerRev
            self.requireTouch = requireTouch
        }
    }

    /// A profile body whose shape the decoder can't use (#195), in the words the DJ sees.
    public struct ShapeError: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// A jog that can't tell how the platter reports movement (#204), in plain words.
    public enum JogError: Error, Equatable, CustomStringConvertible {
        case needsPairOrRelative
        case missing(String)

        public var description: String {
            switch self {
            case .needsPairOrRelative: "jog: needs msb_cc and lsb_cc, or relative_cc"
            case .missing(let key): "jog: \(key) is missing (or set relative_cc for a relative jog)"
            }
        }
    }

    public struct Pitch: Equatable, Sendable, Codable {
        /// 14 for an MSB/LSB pair (the LC6000), or 7 for one CC, `msbCC` (#195).
        public var bits: Int
        public var msbCC: Int
        /// The pair's LSB; a 7-bit fader has none.
        public var lsbCC: Int?
        public var invert: Bool
        public var deadZone: Double
        /// After a load or an outside tempo change, ignore the fader until it meets Syndicate's slider (#22).
        public var pickup: Bool
        /// How close, on the -1...+1 range, counts as meeting it.
        public var pickupTolerance: Double

        enum CodingKeys: String, CodingKey {
            case bits
            case msbCC = "msb_cc"
            case lsbCC = "lsb_cc"
            case invert
            case deadZone = "dead_zone"
            case pickup
            case pickupTolerance = "pickup_tolerance"
        }

        public init(
            msbCC: Int, lsbCC: Int?, invert: Bool, deadZone: Double, pickup: Bool, pickupTolerance: Double, bits: Int = 14
        ) {
            self.bits = bits
            self.msbCC = msbCC
            self.lsbCC = lsbCC
            self.invert = invert
            self.deadZone = deadZone
            self.pickup = pickup
            self.pickupTolerance = pickupTolerance
        }

        /// `pickup` and `pickup_tolerance` may be left out of a profile or mapping file: they default to on and 0.02.
        /// `bits` defaults to 14; a 7-bit fader may leave out `lsb_cc` (#195).
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bits = try container.decodeIfPresent(Int.self, forKey: .bits) ?? ProfileKeys.fallback("pitch.bits")
            msbCC = try container.decode(Int.self, forKey: .msbCC)
            lsbCC = try container.decodeIfPresent(Int.self, forKey: .lsbCC)
            invert = try container.decode(Bool.self, forKey: .invert)
            deadZone = try container.decode(Double.self, forKey: .deadZone)
            pickup = try container.decodeIfPresent(Bool.self, forKey: .pickup) ?? ProfileKeys.fallback("pitch.pickup")
            pickupTolerance = try container.decodeIfPresent(Double.self, forKey: .pickupTolerance) ?? ProfileKeys.fallback("pitch.pickup_tolerance")
            if bits == 14, lsbCC == nil { throw ShapeError("pitch: lsb_cc is missing (or set bits to 7)") }
        }
    }

    /// The Needle Drop strip: a 14-bit position on an MSB/LSB CC pair (#103), and its touch note.
    public struct Needle: Equatable, Sendable, Codable {
        public var msbCC: Int
        public var lsbCC: Int
        public var touchNote: Int
        public var requireTouch: Bool
        /// Whether the strip moves the deck's channel fader (#609): on a plain touch since #729, with Shift + the strip
        /// seeking; off, the strip seeks either way. `shift_fader` keeps #609's name so existing profiles still load.
        public var shiftFader: Bool
        /// How the strip moves the channel fader (#609): from its level by the travel, or to the finger.
        public var shiftFaderMode: ShiftFaderMode

        public enum ShiftFaderMode: String, Equatable, Sendable, Codable, CaseIterable {
            case relative, jump
        }

        enum CodingKeys: String, CodingKey {
            case msbCC = "msb_cc"
            case lsbCC = "lsb_cc"
            case touchNote = "touch_note"
            case requireTouch = "require_touch"
            case shiftFader = "shift_fader"
            case shiftFaderMode = "shift_fader_mode"
        }

        public init(msbCC: Int, lsbCC: Int, touchNote: Int, requireTouch: Bool, shiftFader: Bool = false,
                    shiftFaderMode: ShiftFaderMode = .relative) {
            self.msbCC = msbCC
            self.lsbCC = lsbCC
            self.touchNote = touchNote
            self.requireTouch = requireTouch
            self.shiftFader = shiftFader
            self.shiftFaderMode = shiftFaderMode
        }

        /// `shift_fader` and `shift_fader_mode` may be left out: off, and relative.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            msbCC = try container.decode(Int.self, forKey: .msbCC)
            lsbCC = try container.decode(Int.self, forKey: .lsbCC)
            touchNote = try container.decode(Int.self, forKey: .touchNote)
            requireTouch = try container.decode(Bool.self, forKey: .requireTouch)
            shiftFader = try container.decodeIfPresent(Bool.self, forKey: .shiftFader) ?? ProfileKeys.fallback("needle.shift_fader")
            shiftFaderMode = try container.decodeIfPresent(ShiftFaderMode.self, forKey: .shiftFaderMode)
                ?? ProfileKeys.fallback("needle.shift_fader_mode")
        }
    }

    public struct Browse: Equatable, Sendable, Codable {
        public var selectTurnCC: Int
        public var autoLoopSizeCC: Int

        enum CodingKeys: String, CodingKey {
            case selectTurnCC = "select_turn_cc"
            case autoLoopSizeCC = "auto_loop_size_cc"
        }

        public init(selectTurnCC: Int, autoLoopSizeCC: Int) {
            self.selectTurnCC = selectTurnCC
            self.autoLoopSizeCC = autoLoopSizeCC
        }
    }

    /// Button notes by name (as in the Python mapping), plus the eight pad notes.
    public struct Notes: Equatable, Sendable, Codable {
        public var buttons: [String: Int]
        public var pads: [Int]
        /// Shift done in hardware (#226): the note a button sends with Shift held. Empty on the LC6000, whose Shift
        /// the app works out itself; a button not named here keeps the app's Shift.
        public var shifted: [String: Int]

        public init(buttons: [String: Int], pads: [Int], shifted: [String: Int] = [:]) {
            self.buttons = buttons
            self.pads = pads
            self.shifted = shifted
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            pads = try container.decode([Int].self, forKey: Key(stringValue: "pads"))
            shifted = try container.decodeIfPresent([String: Int].self, forKey: Key(stringValue: "shifted")) ?? ProfileKeys.fallback("notes.shifted")
            buttons = [:]
            for key in container.allKeys where !["pads", "shifted"].contains(key.stringValue) {
                buttons[key.stringValue] = try container.decode(Int.self, forKey: key)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            for (name, note) in buttons { try container.encode(note, forKey: Key(stringValue: name)) }
            try container.encode(pads, forKey: Key(stringValue: "pads"))
            // Only when named, so a profile without hardware Shift (the LC6000) saves as before.
            if !shifted.isEmpty { try container.encode(shifted, forKey: Key(stringValue: "shifted")) }
        }
    }

    public struct LEDs: Equatable, Sendable, Codable {
        public var pitchCenter: Int
        /// The pitch arrows (#475): lit during pickup to show which way to move the fader. Back is toward a lower raw
        /// fader value, forward toward a higher one. Optional: a controller without them leaves them out.
        public var pitchArrowBack: Int?
        public var pitchArrowForward: Int?
        public var ring: Int
        /// The ring color when `ringFollowsDeck` is off.
        public var ringColor: [Int]
        /// The ring shows its deck's badge color (#122). On in the bundled profile; a file without the key inherits it.
        public var ringFollowsDeck: Bool
        public var rollPadColor: [Int]
        public var loopPadColor: [Int]
        public var dimUnlitButtons: Bool
        /// Pulse the platter ring on Syndicate's master clock: never, on every beat, or on the downbeat only.
        public var beatPulse: BeatPulse
        /// How long the ring stays lit after each pulsed beat.
        public var pulseMs: Int
        /// What Syndicate's LEDs show once feedback has stopped: dim, or off.
        public var staleIdle: StaleIdle
        /// The velocities a button LED takes for full, dim and off (#194).
        public var levels: LEDLevels
        /// How a pad or ring color becomes a velocity (#197): the LC6000's rgb222 unless a profile lists its own.
        public var colorTable: ColorTable
        /// Light a button's shifted note (#226) with the button's own state, on a controller where it has its own LED.
        public var mirrorShifted: Bool
        /// The LEDs that take Denon's color message (#530): exact RGB, 7 bits a channel, in place of a velocity. Nil
        /// on a controller without it.
        public var colorMessage: ColorMessage?

        /// Which notes' LEDs take the color message (#530).
        public struct ColorMessage: Equatable, Sendable, Codable {
            public var notes: [Int]
            public init(notes: [Int]) { self.notes = notes }
        }

        public enum BeatPulse: String, Equatable, Sendable, Codable, CaseIterable {
            case off, beat, downbeat
        }

        public enum StaleIdle: String, Equatable, Sendable, Codable, CaseIterable {
            case dim, off
        }

        enum CodingKeys: String, CodingKey {
            case pitchCenter = "pitch_center"
            case pitchArrowBack = "pitch_arrow_back"
            case pitchArrowForward = "pitch_arrow_forward"
            case ring
            case ringColor = "ring_color"
            case ringFollowsDeck = "ring_follows_deck"
            case rollPadColor = "roll_pad_color"
            case loopPadColor = "loop_pad_color"
            case dimUnlitButtons = "dim_unlit_buttons"
            case beatPulse = "beat_pulse"
            case pulseMs = "pulse_ms"
            case staleIdle = "stale_idle"
            case levels
            case colorTable = "color_table"
            case mirrorShifted = "mirror_shifted"
            case colorMessage = "color_message"
        }

        public init(
            pitchCenter: Int, ring: Int, ringColor: [Int], rollPadColor: [Int], loopPadColor: [Int], dimUnlitButtons: Bool,
            beatPulse: BeatPulse, pulseMs: Int, staleIdle: StaleIdle, ringFollowsDeck: Bool = true, levels: LEDLevels = .lc6000,
            colorTable: ColorTable = .rgb222,
            mirrorShifted: Bool = false, pitchArrowBack: Int? = nil, pitchArrowForward: Int? = nil,
            colorMessage: ColorMessage? = nil
        ) {
            self.colorMessage = colorMessage
            self.pitchArrowBack = pitchArrowBack
            self.pitchArrowForward = pitchArrowForward
            self.levels = levels
            self.colorTable = colorTable
            self.mirrorShifted = mirrorShifted
            self.ringFollowsDeck = ringFollowsDeck
            self.pitchCenter = pitchCenter
            self.ring = ring
            self.ringColor = ringColor
            self.rollPadColor = rollPadColor
            self.loopPadColor = loopPadColor
            self.dimUnlitButtons = dimUnlitButtons
            self.beatPulse = beatPulse
            self.pulseMs = pulseMs
            self.staleIdle = staleIdle
        }

        /// A profile written before #122 has no ring_follows_deck: following the deck is the default.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                pitchCenter: try c.decode(Int.self, forKey: .pitchCenter), ring: try c.decode(Int.self, forKey: .ring),
                ringColor: try c.decode([Int].self, forKey: .ringColor),
                rollPadColor: try c.decode([Int].self, forKey: .rollPadColor),
                loopPadColor: try c.decode([Int].self, forKey: .loopPadColor),
                dimUnlitButtons: try c.decode(Bool.self, forKey: .dimUnlitButtons),
                beatPulse: try c.decode(BeatPulse.self, forKey: .beatPulse), pulseMs: try c.decode(Int.self, forKey: .pulseMs),
                staleIdle: try c.decode(StaleIdle.self, forKey: .staleIdle),
                ringFollowsDeck: try c.decodeIfPresent(Bool.self, forKey: .ringFollowsDeck) ?? ProfileKeys.fallback("leds.ring_follows_deck"),
                levels: try c.decodeIfPresent(LEDLevels.self, forKey: .levels) ?? .lc6000,
                colorTable: try c.decodeIfPresent(ColorTable.self, forKey: .colorTable) ?? ProfileKeys.fallback("leds.color_table"),
                mirrorShifted: try c.decodeIfPresent(Bool.self, forKey: .mirrorShifted) ?? ProfileKeys.fallback("leds.mirror_shifted"),
                pitchArrowBack: try c.decodeIfPresent(Int.self, forKey: .pitchArrowBack),
                pitchArrowForward: try c.decodeIfPresent(Int.self, forKey: .pitchArrowForward),
                colorMessage: try c.decodeIfPresent(ColorMessage.self, forKey: .colorMessage)
            )
        }
    }

    /// A button LED's velocity for full, dim and off (#194). Each member may be left out: the LC6000's 127, 1 and 0.
    public struct LEDLevels: Equatable, Sendable, Codable {
        public var full: Int
        public var dim: Int
        public var off: Int

        public static let lc6000 = LEDLevels(full: ProfileKeys.fallback("leds.levels.full"), dim: ProfileKeys.fallback("leds.levels.dim"),
                                             off: ProfileKeys.fallback("leds.levels.off"))

        public init(full: Int, dim: Int, off: Int) {
            self.full = full
            self.dim = dim
            self.off = off
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            full = try c.decodeIfPresent(Int.self, forKey: .full) ?? ProfileKeys.fallback("leds.levels.full")
            dim = try c.decodeIfPresent(Int.self, forKey: .dim) ?? ProfileKeys.fallback("leds.levels.dim")
            off = try c.decodeIfPresent(Int.self, forKey: .off) ?? ProfileKeys.fallback("leds.levels.off")
        }

        enum CodingKeys: String, CodingKey { case full, dim, off }
    }

    /// The mapping that ships with the app.
    public static func bundledDefault() throws -> Mapping {
        try checked(defaultJSON())
    }

    /// A whole mapping body, through the full check (#24) first: every problem at once, or the decoded mapping.
    static func checked(_ json: Data, schema: OrderedJSON? = nil, whole: Bool = false) throws -> Mapping {
        let problems: [String]
        do { problems = Self.problems(in: try OrderedJSON(parsing: json), schema: schema, whole: whole) } catch { problems = ["\(error)"] }
        guard problems.isEmpty else { throw MappingError.invalid(problems) }
        do {
            return try JSONDecoder().decode(Mapping.self, from: json)
        } catch let error as JogError {
            throw MappingError.invalid([error.description])
        } catch let error as ShapeError {
            throw MappingError.invalid([error.description])
        } catch let error as DecodingError {
            // The check runs first, so this shouldn't happen; if it does, the DJ still gets words, not a dump (#92).
            throw MappingError.invalid([Self.describe(error)])
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context? = switch error {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c): c
        @unknown default: nil
        }
        let path = context?.codingPath.map(\.stringValue).joined(separator: ".") ?? ""
        return (path.isEmpty ? "mapping" : path) + ": the value can't be used here"
    }

    /// The bundled default with a user mapping file merged over it, as the Python config merge does: objects merge
    /// key by key, at any depth; anything else (a list, a number, a string) replaces the default whole. Bad JSON or
    /// bad values throw `MappingError` with readable problems.
    public static func bundledDefault(overriddenBy override: Data) throws -> Mapping {
        let user: OrderedJSON
        do { user = try OrderedJSON(parsing: override) } catch { throw MappingError.invalid(["\(error)"]) }
        let base = try OrderedJSON(parsing: defaultJSON())
        return try checked(merge(base, user).data())
    }

    /// The default mapping: the body of the bundled LC6000 profile, the first controller this app supports.
    static func defaultJSON() throws -> Data {
        try ControllerProfile.mappingJSON(of: ControllerProfile.bundledFile("denon-lc6000-prime"))
    }
}

/// A mapping the bridge can't run with. Each problem names the key and what was expected.
public enum MappingError: Error, Equatable {
    case invalid([String])
}

extension Mapping {
    /// A fader or knob: one CC (7-bit) or an MSB/LSB pair (14-bit), as the pitch fader (#195, #207).
    public struct Control: Equatable, Sendable, Codable {
        public var bits: Int
        public var msbCC: Int
        public var lsbCC: Int?

        public init(bits: Int, msbCC: Int, lsbCC: Int?) {
            self.bits = bits
            self.msbCC = msbCC
            self.lsbCC = lsbCC
        }

        enum CodingKeys: String, CodingKey { case bits, msbCC = "msb_cc", lsbCC = "lsb_cc" }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bits = try c.decodeIfPresent(Int.self, forKey: .bits) ?? ProfileKeys.fallback("mixer.volume.bits")
            msbCC = try c.decode(Int.self, forKey: .msbCC)
            lsbCC = try c.decodeIfPresent(Int.self, forKey: .lsbCC)
            if bits == 14, lsbCC == nil {
                let name = c.codingPath.last.map { "mixer.\($0.stringValue)" } ?? "mixer"
                throw ShapeError("\(name): lsb_cc is missing (or set bits to 7)")
            }
        }
    }

    /// The mixer section (#207). Every control is optional and on the controller entry's MIDI channel; the mixer
    /// channel is the deck the entry drives.
    public struct Mixer: Equatable, Sendable, Codable {
        public var volume: Control?
        public var trim: Control?
        public var eqHigh: Control?
        public var eqMid: Control?
        public var eqLow: Control?
        public var filter: Control?
        public var filterRes: Control?
        public var filterWidth: Control?
        /// The headphone cue, mute and solo buttons: a note each, whose LED follows Syndicate.
        public var cueNote: Int?
        public var muteNote: Int?
        public var soloNote: Int?
        public var meter: Meter?
        /// As the pitch fader's (#22): after Syndicate reports a value the controller didn't send, a control waits
        /// until it meets it.
        public var pickup: Bool
        public var pickupTolerance: Double

        /// The channel's VU meter LEDs: one CC whose value lights a number of segments.
        public struct Meter: Equatable, Sendable, Codable {
            public var cc: Int
            /// The CC value for 0, 1, 2… segments lit, lowest first.
            public var steps: [Int]
            /// The value for a clip (Syndicate's Meter above 1.0); nil keeps the top step.
            public var clip: Int?
            /// How long a peak holds before the meter falls back, in milliseconds.
            public var holdMs: Int
            /// The most updates a second, per channel.
            public var rateHz: Int

            public init(cc: Int, steps: [Int], clip: Int?, holdMs: Int, rateHz: Int) {
                self.cc = cc
                self.steps = steps
                self.clip = clip
                self.holdMs = holdMs
                self.rateHz = rateHz
            }

            enum CodingKeys: String, CodingKey { case cc, steps, clip, holdMs = "hold_ms", rateHz = "rate_hz" }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                cc = try c.decode(Int.self, forKey: .cc)
                steps = try c.decode([Int].self, forKey: .steps)
                clip = try c.decodeIfPresent(Int.self, forKey: .clip)
                holdMs = try c.decodeIfPresent(Int.self, forKey: .holdMs) ?? ProfileKeys.fallback("mixer.meter.hold_ms")
                rateHz = try c.decodeIfPresent(Int.self, forKey: .rateHz) ?? ProfileKeys.fallback("mixer.meter.rate_hz")
            }
        }

        enum CodingKeys: String, CodingKey {
            case volume, trim, eqHigh = "eq_high", eqMid = "eq_mid", eqLow = "eq_low", filter
            case filterRes = "filter_res", filterWidth = "filter_width"
            case cueNote = "cue_note", muteNote = "mute_note", soloNote = "solo_note", meter, pickup
            case pickupTolerance = "pickup_tolerance"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            volume = try c.decodeIfPresent(Control.self, forKey: .volume)
            trim = try c.decodeIfPresent(Control.self, forKey: .trim)
            eqHigh = try c.decodeIfPresent(Control.self, forKey: .eqHigh)
            eqMid = try c.decodeIfPresent(Control.self, forKey: .eqMid)
            eqLow = try c.decodeIfPresent(Control.self, forKey: .eqLow)
            filter = try c.decodeIfPresent(Control.self, forKey: .filter)
            filterRes = try c.decodeIfPresent(Control.self, forKey: .filterRes)
            filterWidth = try c.decodeIfPresent(Control.self, forKey: .filterWidth)
            cueNote = try c.decodeIfPresent(Int.self, forKey: .cueNote)
            muteNote = try c.decodeIfPresent(Int.self, forKey: .muteNote)
            soloNote = try c.decodeIfPresent(Int.self, forKey: .soloNote)
            meter = try c.decodeIfPresent(Meter.self, forKey: .meter)
            pickup = try c.decodeIfPresent(Bool.self, forKey: .pickup) ?? ProfileKeys.fallback("mixer.pickup")
            pickupTolerance = try c.decodeIfPresent(Double.self, forKey: .pickupTolerance) ?? ProfileKeys.fallback("mixer.pickup_tolerance")
        }
    }
}
