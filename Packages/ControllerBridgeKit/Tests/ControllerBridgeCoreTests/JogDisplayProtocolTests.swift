import Foundation
@testable import ControllerBridgeCore
import Testing

/// The LC6000 jog display's upload protocol (#121, #165): Denon's SysEx frame, the 21-bit numbers, the 7-bit
/// bitstream and the byte-sum. Literals worked from the protocol notes on #121, checked against
/// tools/lc6000-display/jogbuild.py. Test data is synthetic: no other app's bytes.
@Suite("Jog display protocol")
struct JogDisplayProtocolTests {
    @Test("A frame is F0 00 02 0B 7F 10, the command, a 14-bit length, the payload, F7")
    func frame() {
        #expect(JogDisplay.frame(0x0C, JogDisplay.u21(3)) == [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x0C, 0x00, 0x03, 0x00, 0x00, 0x03, 0xF7])
        #expect(JogDisplay.frame(0x10, []) == [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x10, 0x00, 0x00, 0xF7])
    }

    @Test("A 21-bit number is three 7-bit bytes, most significant first")
    func u21() {
        #expect(JogDisplay.u21(14332) == [0x00, 0x6F, 0x7C])
        #expect(JogDisplay.u21(0x1FFFFF) == [0x7F, 0x7F, 0x7F])
    }

    @Test("The data is an MSB-first bitstream in 7-bit bytes, zero-padded: n*8/7 + 1 bytes")
    func bits7() {
        #expect(JogDisplay.bits7([0xFF]) == [0x7F, 0x40])
        #expect(JogDisplay.bits7([1, 2, 3]) == [0x00, 0x40, 0x40, 0x30])
        #expect(JogDisplay.bits7([UInt8](repeating: 0xFF, count: 7)) == [0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x00])
    }

    @Test("0E is the slot, then the image's 32-bit byte-sum as 8 nibbles: 6 for [1, 2, 3]; 0x3AEE x 0xFF is 0x003AB312")
    func checksum() {
        #expect(JogDisplay.checksum([1, 2, 3], slot: 1) == [0x01, 0, 0, 0, 0, 0, 0, 0, 6])
        #expect(JogDisplay.checksum([UInt8](repeating: 0xFF, count: 0x3AEE), slot: 2) == [0x02, 0x0, 0x0, 0x3, 0xA, 0xB, 0x3, 0x1, 0x2])
    }

    @Test("The hello and goodbye on the Controller port, and showing a slot on WD")
    func helloShowGoodbye() {
        #expect(JogDisplay.hello == [
            [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x60, 0x00, 0x04, 0x04, 0x01, 0x01, 0x00, 0xF7],
            [0xF0, 0x00, 0x20, 0x7F, 0x01, 0xF7],
        ])
        #expect(JogDisplay.goodbye == [0xF0, 0x00, 0x20, 0x7F, 0x02, 0xF7])
    }

    @Test("Show keeps the needle: element mask 0D (image and needle), as djay sends; 01 hid the needle on hardware (#165)")
    func showKeepsNeedle() {
        #expect(JogDisplay.show(slot: 2) == [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x0A, 0x00, 0x04, 0x0D, 0x00, 0x02, 0x0D, 0xF7])
    }
}

@Suite("Jog display upload")
struct JogDisplayUploadTests {
    @Test("A 3-byte image into slot 2: 90 01 00, then 0A index 06, 0C size, one 0D, 0E; then identity, 10 commit; show 2")
    func small() {
        let upload = JogDisplay.Upload(image: [1, 2, 3], slot: 2)
        #expect(upload.start == [[0x90, 0x01, 0x00]])
        #expect(upload.body == [
            [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x06, 0x0D, 0xF7],
            [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x0C, 0x00, 0x03, 0x00, 0x00, 0x03, 0xF7],
            [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x0D, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x40, 0x40, 0x30, 0xF7],
            [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x0E, 0x00, 0x09, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0xF7],
        ])
        // Each upload message but the first is acked: the count seen on hardware.
        #expect(upload.expectedAcks == 3)
        #expect(upload.finish == [[0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7], [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x10, 0x00, 0x00, 0xF7]])
        #expect(upload.show == JogDisplay.show(slot: 2))
    }

    @Test("An upload can lead with a slot to show while it goes up (the loading graphic in slot 5, on hardware) instead of the blank")
    func leadsWithLoading() {
        let upload = JogDisplay.Upload(image: [1, 2, 3], slot: 2, showing: 5)
        #expect(upload.body.first == [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x0A, 0x00, 0x04, 0x0D, 0x00, 0x05, 0x0D, 0xF7])
        #expect(Array(upload.body.dropFirst()) == Array(JogDisplay.Upload(image: [1, 2, 3], slot: 2).body.dropFirst()))
        #expect(upload.expectedAcks == 3)
    }

    @Test("14,333 bytes is two 0D chunks: 14,332 bytes at offset 0 (length 0x7F7F), then 1 byte (0xAB → 55 40) at 14,332")
    func twoChunks() {
        let upload = JogDisplay.Upload(image: [UInt8](repeating: 0xAB, count: 14333), slot: 1)
        let chunks = upload.body.filter { $0[6] == 0x0D }
        #expect(chunks.count == 2)
        #expect(Array(chunks[0][7...11]) == [0x7F, 0x7F, 0x00, 0x00, 0x00])
        #expect(chunks[0].count == 16393)
        #expect(chunks[1] == [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x0D, 0x00, 0x05, 0x00, 0x6F, 0x7C, 0x55, 0x40, 0xF7])
        #expect(upload.expectedAcks == 4)
    }
}

@Suite("Jog display replies")
struct JogDisplayReplyTests {
    @Test("An ack is F0 00 02 0B 01 10 0F 00 01 <status> F7: 00 accepted, anything else refused (06 seen)")
    func acks() {
        #expect(JogDisplay.Reply([0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x0F, 0x00, 0x01, 0x00, 0xF7]) == .accepted)
        #expect(JogDisplay.Reply([0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x0F, 0x00, 0x01, 0x06, 0xF7]) == .refused(0x06))
    }

    @Test("The unit's 01 10 10 is the commit done; anything else is nothing")
    func commitAndOthers() {
        #expect(JogDisplay.Reply([0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x10, 0x00, 0x00, 0xF7]) == .committed)
        #expect(JogDisplay.Reply([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x00, 0x02, 0x0B, 0xF7]) == nil)   // an identity reply
        #expect(JogDisplay.Reply([0x9F, 0x37, 0x7F]) == nil)
        #expect(JogDisplay.Reply([0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x0F, 0xF7]) == nil)          // too short to read
    }
}
