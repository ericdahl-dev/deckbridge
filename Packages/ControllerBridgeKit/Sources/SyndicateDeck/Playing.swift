import ControllerBridgeCore
import Darwin

/// Whether a deck is playing, from Syndicate's feedback (#680). The tool hears it only while the feedback port is free:
/// DeckBridge holds that port while it runs, and then the tool says it can't tell.
public enum Playing {
    /// The deck's Playing in one feedback datagram, a message or a bundle; nil if it has none.
    public static func state(in datagram: [UInt8], deck: Int) -> Bool? {
        guard let packet = try? OSCPacket(decoding: datagram) else { return nil }
        let address = "/syndicate/deck/\(deck)/playing"
        var state: Bool?
        for message in packet.messages where message.address.lowercased() == address {
            switch message.arguments.first {
            case .int(let value): state = value != 0
            case .float(let value): state = value != 0
            default: break
            }
        }
        return state
    }

    /// A socket on the feedback port at 127.0.0.1, or nil when another app (DeckBridge) has it.
    public final class Listener {
        private let fd: Int32

        public init?(port: Int) {
            guard var address = try? UDP.ipv4("127.0.0.1", port) else { return nil }
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return nil }
            // No SO_REUSEPORT: sharing the port would steal DeckBridge's feedback.
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else {
                Darwin.close(fd)
                return nil
            }
            self.fd = fd
        }

        /// The deck's Playing from the first feedback that says it, within `seconds`; nil if none came.
        public func wait(deck: Int, seconds: Double) -> Bool? {
            let deadline = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 + seconds
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let left = deadline - Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
                guard left > 0 else { return nil }
                var timeout = timeval(tv_sec: Int(left), tv_usec: Int32((left - Double(Int(left))) * 1e6))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count > 0 else { continue }
                if let state = state(in: Array(buffer[0..<count]), deck: deck) { return state }
            }
        }

        public func close() { Darwin.close(fd) }
    }
}
