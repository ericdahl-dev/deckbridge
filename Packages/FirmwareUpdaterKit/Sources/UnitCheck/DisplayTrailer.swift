/// The display chip's image trailer, as tools/lc6000-firmware/dfupatch.py checks it (chip, covered_length): the last
/// 32 bytes hold 0xDEADBEEF at -28, the covered length (the size less 20) at -24, the STM32 CRC of everything before
/// it at -20, and "EndOfFlashToken\0" at -16.
enum DisplayTrailer {
    /// The stored CRC, when the trailer is whole and the CRC matches; else nil.
    static func crc(of app: [UInt8]) -> UInt32? {
        let size = app.count
        guard size >= 32, size % 4 == 0, Array(app[(size - 16)...]) == Array("EndOfFlashToken\u{0}".utf8),
              word(app, size - 28) == 0xDEAD_BEEF, word(app, size - 24) == UInt32(size - 20) else { return nil }
        let stored = word(app, size - 20)
        return stm32CRC(app[..<(size - 20)]) == stored ? stored : nil
    }

    private static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    /// The STM32 CRC unit (dfupatch.py's stm32_crc): poly 0x04C11DB7 from 0xFFFFFFFF over little-endian 32-bit words,
    /// most significant bit first, no reflection, no final XOR.
    static func stm32CRC(_ data: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        var i = data.startIndex
        while i < data.endIndex {
            let word = UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
            crc ^= word
            for _ in 0..<4 { crc = crc << 8 ^ table[Int(crc >> 24)] }
            i += 4
        }
        return crc
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n) << 24
        for _ in 0..<8 { c = c & 0x8000_0000 != 0 ? c << 1 ^ 0x04C1_1DB7 : c << 1 }
        return c
    }
}
