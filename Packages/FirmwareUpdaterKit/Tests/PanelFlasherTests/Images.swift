/// A deck panel app image's shape (esp_image_header_t): magic E9 first, and the chip id 9 (ESP32-S3) at bytes 12-13,
/// little-endian. The rest is made up.
func panelApp(count: Int, salt: Int = 7) -> [UInt8] {
    var bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0 * salt + 1) }
    bytes[0] = 0xE9
    bytes[12] = 0x09
    bytes[13] = 0x00
    return bytes
}
