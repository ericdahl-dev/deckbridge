import Testing
@testable import PanelFlasher

// The ROM bootloader's packets (#687): a command header and data, SLIP-framed. Vectors from esptool 5.3.0
// (esptool/loader.py: command() packs "<BBHI" direction 0, op, data length, checksum, then the data, and slip-encodes).

@Test func syncIsTheBytesEsptoolSends() {
    // SYNC (op 0x08): 07 07 12 20 then 32 × 55, checksum 0.
    let expected: [UInt8] = [0xC0, 0x00, 0x08, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x07, 0x12, 0x20]
        + [UInt8](repeating: 0x55, count: 32) + [0xC0]
    #expect(Packet.command(.sync, data: Packet.syncData) == expected)
}

@Test func c0AndDbInsideAPacketAreEscapedAsSlipSays() {
    // RFC 1055 as the ROM reads it: C0 → DB DC, DB → DB DD.
    #expect(Packet.command(.flashData, data: [0xC0, 0xDB], checksum: 0xC0)
        == [0xC0, 0x00, 0x03, 0x02, 0x00, 0xDB, 0xDC, 0x00, 0x00, 0x00, 0xDB, 0xDC, 0xDB, 0xDD, 0xC0])
}

// esptool's check_command: the status is the two bytes right after the data the command answers with, and the
// ROM (unlike the stub) sends two reserved bytes after them.
@Test func aRomResponseGivesItsValueItsDataAndTheStatusRightAfterIt() throws {
    // SYNC's answer: no data, value 0x12345678, status 00 00, then the ROM's two reserved bytes.
    let sync = try #require(Packet.response([0x01, 0x08, 0x04, 0x00, 0x78, 0x56, 0x34, 0x12, 0x00, 0x00, 0x00, 0x00],
                                            dataLength: 0))
    #expect(sync.op == 0x08)
    #expect(sync.value == 0x1234_5678)
    #expect(sync.data == [])
    #expect(sync.ok)
    // Two bytes of data (as MD5's 32, shortened), status 00 00, reserved FF FF: ok, whatever the reserved bytes are.
    let answer = try #require(Packet.response([0x01, 0x13, 0x06, 0x00, 0, 0, 0, 0, 0xAA, 0xBB, 0x00, 0x00, 0xFF, 0xFF],
                                              dataLength: 2))
    #expect(answer.data == [0xAA, 0xBB])
    #expect(answer.ok)
    // A failed command: status 01, reason 05 (the ROM's "invalid message").
    let failed = try #require(Packet.response([0x01, 0x02, 0x04, 0x00, 0, 0, 0, 0, 0x01, 0x05, 0x00, 0x00], dataLength: 0))
    #expect(!failed.ok)
    #expect(failed.error == 0x05)
    // Shorter than the data and status asked for: no response.
    #expect(Packet.response([0x01, 0x13, 0x02, 0x00, 0, 0, 0, 0, 0x00, 0x00], dataLength: 32) == nil)
    // Shorter, with a failed status first: a refusal (esptool reads the first two bytes as the status then).
    let short = try #require(Packet.response([0x01, 0x14, 0x04, 0x00, 0, 0, 0, 0, 0x01, 0x05, 0x00, 0x00], dataLength: 20))
    #expect(!short.ok)
    #expect(short.error == 0x05)
}

@Test func slipFramesAreSplitAndUnescapedFromARunOfBytes() {
    var reader = SlipReader()
    let frames = reader.feed([0x00, 0xC0, 0x01, 0xDB, 0xDC, 0xDB, 0xDD, 0xC0, 0xC0, 0x02]) + reader.feed([0x03, 0xC0])
    #expect(frames == [[0x01, 0xC0, 0xDB], [0x02, 0x03]])
}
