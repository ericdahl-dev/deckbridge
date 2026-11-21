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
        #expect(port.writes.withLock { $0 } == [SLIP.frame(OSCPacket.bundle(messages))])
    }
}
