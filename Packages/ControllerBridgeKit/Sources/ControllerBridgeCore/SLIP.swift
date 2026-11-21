// SLIP framing (RFC 1055) for the display feed over the USB cable (#667), as OSC 1.1 has it for serial. Pure, no I/O.

public enum SLIP {
    static let end: UInt8 = 0xC0
    static let esc: UInt8 = 0xDB
    static let escEnd: UInt8 = 0xDC
    static let escEsc: UInt8 = 0xDD

    /// One packet as one frame: END before and after, so a panel that missed bytes starts clean at the next frame.
    public static func frame(_ packet: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [end]
        out.reserveCapacity(packet.count + 2)
        for byte in packet {
            switch byte {
            case end: out += [esc, escEnd]
            case esc: out += [esc, escEsc]
            default: out.append(byte)
            }
        }
        out.append(end)
        return out
    }
}
