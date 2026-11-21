/// The ROM bootloader's commands the flasher sends (esptool/loader.py, ESP_CMDS).
enum Op: UInt8 {
    case flashData = 0x03
    case sync = 0x08
    case changeSpeed = 0x0F
    case securityInfo = 0x14
}

/// One packet to or from the ESP32-S3's ROM serial bootloader: a header (direction, op, data length, a 32-bit value
/// or checksum), then the data, framed with SLIP (RFC 1055).
enum Packet {
    static let end: UInt8 = 0xC0, escape: UInt8 = 0xDB, escapedEnd: UInt8 = 0xDC, escapedEscape: UInt8 = 0xDD

    /// SYNC's data: 07 07 12 20, then 32 × 55.
    static let syncData: [UInt8] = [0x07, 0x07, 0x12, 0x20] + [UInt8](repeating: 0x55, count: 32)

    /// A command, SLIP-framed: direction 0, op, data length (16-bit), checksum (32-bit), all little-endian.
    static func command(_ op: Op, data: [UInt8], checksum: UInt32 = 0) -> [UInt8] {
        let body = [0x00, op.rawValue] + le16(UInt16(data.count)) + le32(checksum) + data
        var out: [UInt8] = [end]
        for byte in body {
            switch byte {
            case end: out += [escape, escapedEnd]
            case escape: out += [escape, escapedEscape]
            default: out.append(byte)
            }
        }
        return out + [end]
    }

    /// A response from an unescaped frame: direction 1, op, length, value, then `dataLength` bytes of data and the
    /// status, 0 for ok or 1 and a reason (esptool's check_command). The ROM's two reserved bytes after the status are
    /// ignored. A frame too short for that data is a refusal if it starts with a failed status, else nil.
    static func response(_ frame: [UInt8], dataLength: Int) -> Response? {
        guard frame.count >= 8, frame[0] == 0x01 else { return nil }
        let length = Int(frame[2]) | Int(frame[3]) << 8
        let body = Array(frame.dropFirst(8).prefix(length))
        let value = UInt32(frame[4]) | UInt32(frame[5]) << 8 | UInt32(frame[6]) << 16 | UInt32(frame[7]) << 24
        guard body.count >= dataLength + 2 else {
            // Too short for the data: a refusal when its first two bytes are a failed status, else nothing.
            guard body.count >= 2, body[0] != 0 else { return nil }
            return Response(op: frame[1], value: value, data: [], ok: false, error: body[1])
        }
        return Response(op: frame[1], value: value, data: Array(body[0..<dataLength]), ok: body[dataLength] == 0,
                        error: body[dataLength + 1])
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
}

struct Response: Equatable {
    var op: UInt8
    var value: UInt32
    var data: [UInt8]
    var ok: Bool
    var error: UInt8
}

/// Splits a run of bytes from the line into unescaped SLIP frames, keeping a frame that is still arriving.
struct SlipReader {
    private var frame: [UInt8] = []
    private var inFrame = false
    private var escaped = false

    mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for byte in bytes {
            if byte == Packet.end {
                if inFrame && !frame.isEmpty { frames.append(frame) }
                frame = []
                inFrame = true
                escaped = false
            } else if !inFrame {
                continue  // anything outside a frame: the ROM's boot text, say
            } else if escaped {
                frame.append(byte == Packet.escapedEnd ? Packet.end : byte == Packet.escapedEscape ? Packet.escape : byte)
                escaped = false
            } else if byte == Packet.escape {
                escaped = true
            } else {
                frame.append(byte)
            }
        }
        return frames
    }
}
