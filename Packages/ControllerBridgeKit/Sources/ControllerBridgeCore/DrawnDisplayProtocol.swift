// Generated from tools/lc6000-display-fw/vectors/messages.json by vectors/gen_protocol.py (#569). Don't edit.

/// The drawn display's protocol, as vectors/messages.json describes it once.
public enum DrawnDisplayProtocol {
    public enum Op: UInt8, CaseIterable, Sendable {
        case capability = 0x00
        case begin = 0x01
        case end = 0x02
        case deck = 0x03
        case text = 0x04
        case tempo = 0x05
        case time = 0x06
        case state = 0x07
        case beat = 0x08
        case needle = 0x09
        case meter = 0x0A
        case phase = 0x0B
    }

    /// An op's one length, counting the op; nil for text (framed by len) and for an op this version doesn't take.
    public static func length(_ op: UInt8) -> Int? {
        switch op {
        case 0x00: 2
        case 0x01: 2
        case 0x02: 2
        case 0x03: 9
        case 0x05: 3
        case 0x06: 5
        case 0x07: 2
        case 0x08: 2
        case 0x09: 3
        case 0x0A: 3
        case 0x0B: 3
        default: nil
        }
    }

    public static let header: [UInt8] = [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10]
    public static let replyHeader: [UInt8] = [0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10]
    public static let command = 0x20
    public static let version = 1
    public static let textMax = 96
    public static let textFields = 4
    public static let messageMax = 112
    public static let deckMax = 4
    public static let playerMax = 5
    public static let beatMax = 4
    /// The state message's flag bits, by name.
    public static let flagBits: [String: Int] = ["loaded": 0, "playing": 1, "play_pending": 2, "cue_held": 3, "loop_on": 4, "stale": 5, "reserved": 6]
    public static let phaseUnknown = -8192
    public static let silenceMs = 3000
    public static let warningSeconds = 60
    public static let blinkSeconds = 30
    public static let blinkHalfMs = 500
}
