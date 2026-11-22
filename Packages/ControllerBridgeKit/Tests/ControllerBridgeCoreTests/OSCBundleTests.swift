import Foundation
@testable import ControllerBridgeCore
import Testing

/// OSC 1.0 bundles out (#636): the display feed's updates go as one datagram each.
@Suite("OSC bundles out")
struct OSCBundleTests {
    @Test("A bundle is #bundle, the time tag 'immediately', then each element's size and message")
    func bytes() {
        let bytes = OSCPacket.bundle([OSCMessage("/a", [.int(1)])])
        let expected: [UInt8] = Array("#bundle\0".utf8) + [0, 0, 0, 0, 0, 0, 0, 1] + [0, 0, 0, 12]
            + Array("/a\0\0".utf8) + Array(",i\0\0".utf8) + [0, 0, 0, 1]
        #expect(bytes == expected)
    }

    @Test("Our own decoder reads a bundle back as its messages, in order")
    func roundTrip() throws {
        let messages = [
            OSCMessage("/DeckBridge/Display/deck", [.int(3)]),
            OSCMessage("/DeckBridge/Display/title", [.string("Café Ångström")]),
            OSCMessage("/DeckBridge/Display/phase", [.float(-1)]),
        ]
        #expect(try OSCPacket(decoding: OSCPacket.bundle(messages)).messages == messages)
    }
}
