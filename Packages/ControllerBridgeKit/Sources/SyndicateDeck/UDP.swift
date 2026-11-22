import ControllerBridgeCore
import Darwin

/// The tool's UDP (#680): one datagram per message, as DeckBridge sends them (App/UDP.swift, which the app keeps to
/// itself), and a short listen for Syndicate's feedback when nobody else holds its port.
public enum UDP {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badAddress(String)
        case call(String, Int32)

        public var description: String {
            switch self {
            case .badAddress(let host): "\(host) is not an IPv4 address"
            case .call(let name, let code): "\(name): \(String(cString: strerror(code)))"
            }
        }
    }

    static func ipv4(_ host: String, _ port: Int) throws(Failure) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw .badAddress(host) }
        return address
    }

    /// Sends each message as one datagram, in order. Nothing listening (Syndicate not running) loses them quietly,
    /// as it does for the app.
    public static func send(_ messages: [OSCMessage], host: String, port: Int) throws(Failure) {
        var address = try ipv4(host, port)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw .call("socket", errno) }
        defer { close(fd) }
        for message in messages {
            let bytes = message.encoded()
            let sent = withUnsafePointer(to: &address) { to in
                to.withMemoryRebound(to: sockaddr.self, capacity: 1) { to in
                    bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, to, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            if sent < 0 && errno != ECONNREFUSED { throw .call("sendto", errno) }
        }
    }
}
