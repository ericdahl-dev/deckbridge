// The jog display's MIDI as Universal MIDI Packets (#165, #309): how the app hands SysEx and voice messages to CoreMIDI
// for the WD and Controller ports, and rebuilds the unit's SysEx answers. Pure math, so it's tested here; the app's
// CoreMIDI code only sends and receives the words.

public enum UMP {
    /// A SysEx message (F0 … F7) as SysEx7 packets of two words: the bytes between F0 and F7, six at a time, each
    /// marked whole (0), start (1), continue (2) or end (3), with its byte count.
    public static func sysex7(_ message: [UInt8]) -> [[UInt32]] {
        let body = Array(message.dropFirst().dropLast())
        let pieces = stride(from: 0, to: max(body.count, 1), by: 6).map { Array(body[$0..<min($0 + 6, body.count)]) }
        return pieces.enumerated().map { index, piece in
            let status: UInt32 = pieces.count == 1 ? 0 : index == 0 ? 1 : index == pieces.count - 1 ? 3 : 2
            let b = piece.map(UInt32.init) + Array(repeating: 0, count: 6 - piece.count)
            return [0x3000_0000 | status << 20 | UInt32(piece.count) << 16 | b[0] << 8 | b[1],
                    b[2] << 24 | b[3] << 16 | b[4] << 8 | b[5]]
        }
    }

    /// A three-byte channel message (pitch bend, a note) as one MIDI 1.0 channel voice word, group 0.
    public static func voice(_ bytes: [UInt8]) -> UInt32 {
        let b = bytes + [0, 0, 0]
        return 0x2000_0000 | UInt32(b[0]) << 16 | UInt32(b[1] & 0x7F) << 8 | UInt32(b[2] & 0x7F)
    }

    /// How many words a packet of this message type takes (UMP spec: types 0–2 one, 3–4 two, 5 four, larger ones
    /// by the same table).
    static func words(type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4
        }
    }
}

/// Rebuilds SysEx from SysEx7 packets, across deliveries. Other packets are stepped over by their own size, so a voice
/// message among them doesn't throw the rest out of step.
public struct SysExReassembler: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// The whole SysEx messages (F0 … F7) these words finish.
    public mutating func feed(_ words: [UInt32]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var index = 0
        while index < words.count {
            let first = words[index], type = first >> 28
            let size = UMP.words(type: type)
            defer { index += size }
            guard type == 3, index + 1 < words.count else { continue }
            let second = words[index + 1]
            let status = first >> 20 & 0xF, count = min(6, Int(first >> 16 & 0xF))
            let bytes = [UInt8(first >> 8 & 0xFF), UInt8(first & 0xFF), UInt8(second >> 24), UInt8(second >> 16 & 0xFF),
                         UInt8(second >> 8 & 0xFF), UInt8(second & 0xFF)].prefix(count)
            if status == 0 || status == 1 { buffer = [] }
            buffer += bytes
            if status == 0 || status == 3 { out.append([0xF0] + buffer + [0xF7]) }
        }
        return out
    }
}
