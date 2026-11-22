import Testing
import UnitCheck

/// A USB string descriptor as a raw GET_DESCRIPTOR returns it: bLength, type 3, then UTF-16LE. The display chip's ROM
/// bootloader only answers the full 255-byte request (cos, the owner's unit: IOUSBHost's string read failed on it).
@Suite("Update mode: a raw string descriptor")
struct StringDescriptorTests {
    static func descriptor(_ text: String, length: Int? = nil) -> [UInt8] {
        let body = text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        return [UInt8(length ?? body.count + 2), 0x03] + body
    }

    @Test("The display chip's alt name, 112 bytes: read whole")
    func displayChipName() {
        let name = "@Internal Flash  /0x08000000/04*016Kg,01*064Kg,07*128Kg"
        let bytes = Self.descriptor(name)
        #expect(bytes.count == 112)
        #expect(StringDescriptor.text(bytes) == name)
    }

    @Test("Trailing bytes past bLength are ignored")
    func pastLength() {
        #expect(StringDescriptor.text(Self.descriptor("@Flash") + [0x41, 0x00]) == "@Flash")
    }

    @Test("Not a string descriptor, too short, or bLength past the bytes: nil",
          arguments: [[], [0x02], [0x04, 0x02, 0x41, 0x00], Self.descriptor("@Flash", length: 40)] as [[UInt8]])
    func notAString(bytes: [UInt8]) {
        #expect(StringDescriptor.text(bytes) == nil)
    }
}
