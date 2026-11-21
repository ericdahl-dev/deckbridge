@testable import ControllerBridgeCore
import Synchronization
import Testing

/// The display feed's sender for the USB cable (#667): each packet goes to the port as one SLIP frame in one write.
@Suite("Display feed: the USB cable's sender")
struct CableFeedSenderTests {
    final class FakePort: BytePort {
        let writes = Mutex<[[UInt8]]>([])
        func write(_ bytes: [UInt8]) { writes.withLock { $0.append(bytes) } }
    }

    @Test("a message goes as one frame, the shared example's bytes")
    func aMessageGoesAsOneFrame() throws {
        let port = FakePort()
        CableFeedSender(port).send(OSCMessage("/DeckBridge/Display/color", [.int(0xC0DB00)]))
        let example = try #require(SLIPTests.cases.first { $0["name"] == "the color message for 0xC0DB00" })
        #expect(port.writes.withLock { $0 } == [SLIPTests.bytes(example["framed_hex"]!)])
    }

    @Test("a bundle goes as one frame in one write")
    func aBundleGoesAsOneFrame() {
        let port = FakePort()
        let messages = [OSCMessage("/DeckBridge/Display/deck", [.int(2)]), OSCMessage("/DeckBridge/Display/loaded", [.int(1)])]
        CableFeedSender(port).send(bundle: messages)
        // Built by hand (Python, from the OSC 1.0 and RFC 1055 rules): "#bundle", time tag 1, each message with its size.
        let framed = "c02362756e646c65000000000000000001000000242f4465636b4272696467652f446973706c61792f6465636b00000000"
            + "2c69000000000002000000242f4465636b4272696467652f446973706c61792f6c6f6164656400002c69000000000001c0"
        #expect(port.writes.withLock { $0 } == [SLIPTests.bytes(framed)])
    }
}
