import ControllerBridgeCore
import Darwin
@testable import SyndicateDeck
import Testing

/// Slice 5 (#680): whether the deck is playing, from Syndicate's feedback, when the tool can hear it: only while the
/// feedback port is free, as DeckBridge holds it while it runs.
@Suite("Syndicate deck: is it playing", .serialized)
struct PlayingTests {
    @Test func playingFromFeedbackAsIntOrFloatAloneOrInABundle() {
        let on = OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]).encoded()
        let off = OSCMessage("/Syndicate/Deck/1/Playing", [.float(0)]).encoded()
        let bundled = OSCPacket.bundle([OSCMessage("/Syndicate/Deck/1/Position", [.float(0.5)]),
                                        OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)])])
        #expect(Playing.state(in: on, deck: 1) == true)
        #expect(Playing.state(in: off, deck: 1) == false)
        #expect(Playing.state(in: bundled, deck: 1) == true)
    }

    @Test func anotherDeckOrNoiseSaysNothing() {
        #expect(Playing.state(in: OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]).encoded(), deck: 1) == nil)
        #expect(Playing.state(in: [1, 2, 3], deck: 1) == nil)
    }

    /// A port the system has free right now.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var address = try UDP.ipv4("127.0.0.1", 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        try #require(ok)
        return Int(UInt16(bigEndian: address.sin_port))
    }

    @Test func aHeldPortIsBusyAndTheToolCantTell() throws {
        let port = try Self.freePort()
        let holder = try #require(Playing.Listener(port: port))  // DeckBridge, say
        defer { holder.close() }
        #expect(Playing.Listener(port: port) == nil)
    }

    @Test func aFreePortHearsTheDeck() throws {
        let port = try Self.freePort()
        let listener = try #require(Playing.Listener(port: port))
        defer { listener.close() }
        try UDP.send([OSCMessage("/Syndicate/Deck/3/Playing", [.int(0)]), OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)])],
                     host: "127.0.0.1", port: port)
        #expect(listener.wait(deck: 1, seconds: 1) == true)
    }

    @Test func nothingHeardIsNil() throws {
        let listener = try #require(Playing.Listener(port: try Self.freePort()))
        defer { listener.close() }
        #expect(listener.wait(deck: 1, seconds: 0.2) == nil)
    }
}
