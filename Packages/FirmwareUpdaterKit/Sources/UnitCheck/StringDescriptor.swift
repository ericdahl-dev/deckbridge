/// A USB string descriptor from a raw GET_DESCRIPTOR (bLength, type 3, UTF-16LE text). The display chip's ROM bootloader
/// answers only the full 255-byte request, so the updater reads the alt name raw (cos, on the owner's unit).
public enum StringDescriptor {
    /// The full-length request's wLength.
    public static let requestLength: UInt16 = 255

    /// The text, or nil when `bytes` isn't a whole string descriptor.
    public static func text(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 2, bytes[1] == 0x03 else { return nil }
        let length = Int(bytes[0])
        guard length >= 2, length <= bytes.count else { return nil }
        let body = bytes[2..<length]
        let units = stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }
}
