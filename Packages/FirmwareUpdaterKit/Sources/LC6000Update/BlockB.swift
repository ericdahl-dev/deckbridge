// Block B, the drawn jog display's drawing (#501), as the updater installs it on the display chip (#751): at
// 0x08080000 and up, outside Denon's image. Checked the way block A checks it on the chip (arm/upper.c, with
// arm/upper_header.py the one description of the header): marker "DFWB", version 4, its length, zlib's CRC-32 from +16,
// and draw and band entries that are Thumb code inside B. The layout word (+16) is what block A must match.

public struct BlockB: Sendable, Equatable {
    /// Where B goes: sectors 8-11 of the display chip's 1 MB, up to 512 KB.
    public static let address: UInt32 = 0x0808_0000
    public static let limit = 0x8_0000
    static let marker: UInt32 = 0x4257_4644  // "DFWB"
    static let version: UInt32 = 4
    static let header = 28

    public struct Refused: Error, Equatable {
        public let reason: String
    }

    public let bytes: [UInt8]
    /// The dfw_unit layout B was built for (#516): block A calls B only when it's A's own.
    public let layout: UInt32

    public init(_ bytes: [UInt8]) throws(Refused) {
        guard bytes.count >= Self.header else { throw Refused(reason: "Block B is shorter than its header.") }
        let word = { (at: Int) in (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) } }
        guard word(0) == Self.marker else { throw Refused(reason: "This file isn't block B: it doesn't start with \"DFWB\".") }
        guard word(4) == Self.version else {
            throw Refused(reason: "Block B's header is version \(word(4)); block A takes version \(Self.version).")
        }
        guard word(8) == UInt32(bytes.count), bytes.count <= Self.limit else {
            throw Refused(reason: "Block B's length doesn't match the file, or is over the 512 KB above the image.")
        }
        guard Self.crc32(bytes[16...]) == word(12) else { throw Refused(reason: "Block B's CRC doesn't match its bytes.") }
        let first = Self.address + UInt32(Self.header), end = Self.address + UInt32(bytes.count)
        for (name, entry) in [("draw", word(20)), ("band", word(24))] {
            guard entry & 1 == 1, first <= entry, entry < end else {
                throw Refused(reason: "Block B's \(name) entry isn't Thumb code inside it.")
            }
        }
        self.bytes = bytes
        layout = word(16)
    }

    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
