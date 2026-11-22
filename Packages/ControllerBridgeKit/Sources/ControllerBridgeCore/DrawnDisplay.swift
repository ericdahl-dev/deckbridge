// The drawn jog display's messages (#455): small state messages a unit with the custom display firmware draws itself,
// instead of uploaded images. Denon's frame on the WD port, one command byte for all of them and an op byte. The shared
// vectors (tools/lc6000-display-fw/vectors/messages.json) hold examples both this and the firmware's C are tested on.

import Foundation

/// The jog display firmware DeckBridge found on the unit (#456).
public enum DisplayFound: Equatable, Sendable {
    case denon
    /// Custom firmware that didn't answer as one that draws: uploaded images.
    case customImages
    case customDrawn(version: Int)

    /// What Settings shows.
    public var label: String {
        switch self {
        case .denon: "Denon"
        case .customImages: "Custom (images)"
        case .customDrawn(let version): "Custom (drawn display, protocol \(version))"
        }
    }
}

extension DisplayFirmware {
    /// Settings' Firmware row hint: what the setting means, then what was found on the unit, if anything.
    public func hint(found: DisplayFound?) -> String {
        let meaning = self == .denon
            ? "Denon's own: 15 image slots, so deck 4 shows three of its four beats"
            : "Custom: 16 image slots, or a drawn display if the unit's firmware answers. Only for a flashed unit"
        return found.map { meaning + "\nFound: " + $0.label } ?? meaning
    }
}

public enum DrawnDisplay {
    /// The command byte of every drawn-display message. Denon's display firmware (wd 00.50) drops it silently, with no
    /// reply (#466); the vectors file and the C side carry the same number. Never 78 or 79: they write its settings flash.
    public static let command = UInt8(DrawnDisplayProtocol.command)
    /// The protocol version this app speaks.
    public static let version = DrawnDisplayProtocol.version

    /// What a deck holds, as the badge shows it (#209).
    public enum Player: UInt8, Sendable {
        case empty = 0, track, oscClip, midiClip, sequencer, other

        /// From Syndicate's player type: nil or "empty" is empty.
        public init(playerType: String?) {
            guard let type = playerType?.lowercased(), !type.isEmpty, type != "empty" else { self = .empty; return }
            if type == "track" { self = .track }
            else if type.contains("osc") { self = .oscClip }
            else if type.contains("midi") { self = .midiClip }
            else if type.contains("seq") { self = .sequencer }
            else { self = .other }
        }
    }

    /// The deck in front's state flags (#455): one byte, bit 6 never set.
    public struct State: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue & 0x3F }
        public static let loaded = State(rawValue: 1 << 0)
        public static let playing = State(rawValue: 1 << 1)
        public static let playPending = State(rawValue: 1 << 2)
        public static let cueHeld = State(rawValue: 1 << 3)
        public static let loopOn = State(rawValue: 1 << 4)
        /// Syndicate's feedback stopped: the values shown aren't live (#464).
        public static let stale = State(rawValue: 1 << 5)
    }

    /// Which text a text message carries (#458). The untitled words are the big line with no title, as the image says
    /// it (JogDisplayWords.untitled): "No track", "OSC clip" or the player type's own name; empty with a title.
    public enum TextField: UInt8, Sendable {
        case title = 0, artist, key, untitled
    }

    /// A text as the wire carries it (#458): Windows-1252, a code 0x80-0xFF as 7F then code − 0x80. Control codes and
    /// DEL aren't text and are dropped; a character with no cp1252 code goes as 0x81, which the chip draws as a box.
    /// Cut at a character boundary to `textCap` bytes, never splitting a 7F pair; the chip adds the ellipsis.
    static func escaped(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        for character in text.precomposedStringWithCanonicalMapping {
            let code = cp1252(character)
            if code < 0x20 || code == 0x7F { continue }
            let bytes: [UInt8] = code < 0x80 ? [code] : [0x7F, code - 0x80]
            guard out.count + bytes.count <= textCap else { break }
            out += bytes
        }
        return out
    }

    /// The most escaped text bytes in one text message (#458): agent3's 96, so the whole message is at most 108 bytes,
    /// inside the 128 agent2 found keeps stock's SysEx handling short. Longer messages are dropped with no error.
    static let textCap = DrawnDisplayProtocol.textMax

    /// The character's cp1252 code; 0x81 (the box) for one with none. C1 controls have no glyph: cp1252's undefined
    /// slots must not pass as themselves.
    private static func cp1252(_ character: Character) -> UInt8 {
        let scalars = character.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first, scalar.value < 0x80 { return UInt8(scalar.value) }
        if scalars.contains(where: { (0x80...0x9F).contains($0.value) }) { return 0x81 }
        guard let data = String(character).data(using: .windowsCP1252), data.count == 1 else { return 0x81 }
        return data[data.startIndex]
    }

    public enum Message: Equatable, Sendable {
        /// "Can you draw?", with the newest version the host speaks.
        case capability(version: Int)
        case begin(version: Int)
        case end(version: Int)
        /// The deck in front: its number (1-4), color [r, g, b] (0-255 each) and what it holds.
        case deck(number: Int, color: [Int], player: Player)
        case state(State)
        /// The master clock's beat, 1-4; 0 with no master clock (#459).
        case beat(Int)
        /// The deck's place in its bar, 0-16383 for a turn clockwise from 12 o'clock: the pitch-bend needle's scale.
        case needle(Int)
        /// The deck in front's mixer channel (#461): its level and the peak being held, each 0-127.
        case meter(level: Int, peak: Int)
        /// One of the deck's texts (#458); empty clears that field.
        case text(TextField, String)
        /// The deck's tempo in tenths of a BPM, 1-16383; 0 is none, drawn as "—" (#458).
        case tempo(tenths: Int)
        /// How far the deck in front is from the master clock's beat (#462), in 1/16384 beats: -8191 to 8191,
        /// negative behind, 0 in phase; -8192 is unknown (not playing, no master clock). Sent as 14-bit two's
        /// complement.
        case phase(Int)

        /// How far into its track the deck is, and the track's length, in whole seconds, each 0-16383; length 0 is
        /// unknown (#460). The chip works out what's left.
        case time(elapsedSeconds: Int, lengthSeconds: Int)

        /// The time message from Syndicate's position and length in seconds: each cut to the second shown, clamped to
        /// 16383; an unknown, NaN, zero or negative one is 0.
        public static func time(elapsed: Double?, length: Double?) -> Message {
            func seconds(_ value: Double?) -> Int {
                guard let value, value > 0 else { return 0 }
                return value >= 16383 ? 16383 : Int(value)
            }
            return .time(elapsedSeconds: seconds(elapsed), lengthSeconds: seconds(length))
        }

        /// The tempo message for a BPM: rounded once to tenths, clamped to 16383; 0 for none, NaN, zero or below.
        public static func tempo(_ bpm: Double?) -> Message {
            guard let bpm, bpm > 0 else { return .tempo(tenths: 0) }
            let tenths = (bpm * 10).rounded()
            return .tempo(tenths: tenths >= 16383 ? 16383 : Int(tenths))
        }

        /// The SysEx frame for the WD port.
        public var bytes: [UInt8] {
            switch self {
            case .capability(let version): DrawnDisplay.frame(.capability, [UInt8(version & 0x7F)])
            case .begin(let version): DrawnDisplay.frame(.begin, [UInt8(version & 0x7F)])
            case .end(let version): DrawnDisplay.frame(.end, [UInt8(version & 0x7F)])
            case .deck(let number, let color, let player):
                DrawnDisplay.frame(.deck, [UInt8(number & 0x7F)]
                    + color.prefix(3).flatMap { channel -> [UInt8] in
                        let value = min(max(channel, 0), 255)
                        return [UInt8(value >> 7), UInt8(value & 0x7F)]
                    } + [player.rawValue])
            case .state(let state): DrawnDisplay.frame(.state, [state.rawValue])
            case .beat(let beat): DrawnDisplay.frame(.beat, [UInt8(min(max(beat, 0), 4))])
            case .needle(let angle):
                DrawnDisplay.frame(.needle, [UInt8(angle >> 7 & 0x7F), UInt8(angle & 0x7F)])
            case .meter(let level, let peak):
                DrawnDisplay.frame(.meter, [UInt8(min(max(level, 0), 127)), UInt8(min(max(peak, 0), 127))])
            case .text(let field, let text): DrawnDisplay.frame(.text, [field.rawValue] + DrawnDisplay.escaped(text))
            case .time(let elapsed, let length):
                DrawnDisplay.frame(.time, [UInt8(elapsed >> 7 & 0x7F), UInt8(elapsed & 0x7F),
                                          UInt8(length >> 7 & 0x7F), UInt8(length & 0x7F)])
            case .tempo(let tenths):
                DrawnDisplay.frame(.tempo, [UInt8(tenths >> 7 & 0x7F), UInt8(tenths & 0x7F)])
            case .phase(let offset):
                DrawnDisplay.frame(.phase, [UInt8(offset >> 7 & 0x7F), UInt8(offset & 0x7F)])
            }
        }
    }

    static func frame(_ op: DrawnDisplayProtocol.Op, _ arguments: [UInt8]) -> [UInt8] {
        JogDisplay.frame(command, [op.rawValue] + arguments)
    }

    /// The unit's answer to the capability question: its protocol version, or nil for anything else.
    public static func answer(_ message: [UInt8]) -> Int? {
        let head: [UInt8] = DrawnDisplayProtocol.replyHeader + [command, 0x00, 0x02, DrawnDisplayProtocol.Op.capability.rawValue]
        guard message.count == 12, Array(message.prefix(10)) == head, message[11] == 0xF7,
              (1...0x7F).contains(message[10]) else { return nil }
        return Int(message[10])
    }
}
