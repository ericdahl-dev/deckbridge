import ControllerBridgeCore
import Darwin
@testable import SyndicateDeck
import Testing

/// Slice 4 (#680): each message goes as one datagram, the bytes exactly Core's encoding, in order.
@Suite("Syndicate deck: sending", .serialized)
struct SendTests {
    /// A socket on 127.0.0.1 at a port the system picks, standing in for Syndicate.
    static func listener() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        try #require(fd >= 0 && bound)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    @Test func eachMessageIsOneDatagramOfCoresBytes() throws {
        let (fd, port) = try Self.listener()
        defer { close(fd) }
        let messages = Deck.messages(for: .play(deck: 1, cue: 1))
        try UDP.send(messages, host: "127.0.0.1", port: port)
        for message in messages {
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = recv(fd, &buffer, buffer.count, 0)
            #expect(Array(buffer.prefix(max(count, 0))) == message.encoded())
        }
    }

    @Test func aHostThatIsNotIPv4IsAnError() {
        #expect(throws: UDP.Failure.self) { try UDP.send([], host: "syndicate.local", port: 9090) }
    }
}
