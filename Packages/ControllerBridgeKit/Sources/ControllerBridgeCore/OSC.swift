// Open Sound Control 1.0 messages and bundles. Pure encoding, no networking.

/// One OSC argument.
public enum OSCArgument: Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
}

/// An OSC message: an address and its arguments.
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out.appendOSCString(address)
        var tags = ","
        for argument in arguments {
            switch argument {
            case .int: tags += "i"
            case .float: tags += "f"
            case .string: tags += "s"
            }
        }
        out.appendOSCString(tags)
        for argument in arguments {
            switch argument {
            case .int(let value): out.appendBigEndian(UInt32(bitPattern: value))
            case .float(let value): out.appendBigEndian(value.bitPattern)
            case .string(let value): out.appendOSCString(value)
            }
        }
        return out
    }
}

/// A received OSC packet, flattened to its messages in order.
public struct OSCPacket: Equatable, Sendable {
    public var messages: [OSCMessage]

    public init(decoding bytes: [UInt8]) throws(OSCError) {
        messages = try Self.messages(in: bytes[...], depth: 0)
    }

    /// `messages` as one bundle (#636): "#bundle", the time tag 1 ("immediately"), then each message with its size.
    public static func bundle(_ messages: [OSCMessage]) -> [UInt8] {
        var out = bundleTag + [0, 0, 0, 0, 0, 0, 0, 1]
        for message in messages {
            let bytes = message.encoded()
            out.appendBigEndian(UInt32(bytes.count))
            out += bytes
        }
        return out
    }

    /// Feedback arrives as untrusted UDP, so nesting is capped and every element size is checked.
    static let maxBundleDepth = 8
    private static let bundleTag = Array("#bundle\0".utf8)

    private static func messages(in bytes: ArraySlice<UInt8>, depth: Int) throws(OSCError) -> [OSCMessage] {
        var reader = OSCReader(bytes)
        guard bytes.starts(with: bundleTag) else { return [try reader.message()] }
        guard depth < maxBundleDepth else { throw .malformed("bundles nested too deep") }
        _ = try reader.take(bundleTag.count + 8)   // the tag and the time tag
        var out: [OSCMessage] = []
        while !reader.bytes.isEmpty {
            let size = Int(try reader.uint32())
            out += try messages(in: try reader.take(size), depth: depth + 1)
        }
        return out
    }
}

public enum OSCError: Error, Equatable {
    case truncated
    case malformed(String)
}

private struct OSCReader {
    var bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }

    mutating func message() throws(OSCError) -> OSCMessage {
        let address = try string()
        guard address.hasPrefix("/") else { throw .malformed("address must start with /") }
        let tags = try string()
        guard tags.hasPrefix(",") else { throw .malformed("missing type tag string") }
        var arguments: [OSCArgument] = []
        tags: for tag in tags.utf8.dropFirst() {
            switch Character(UnicodeScalar(tag)) {
            case "i": arguments.append(.int(Int32(bitPattern: try uint32())))
            case "f": arguments.append(.float(Float(bitPattern: try uint32())))
            case "s": arguments.append(.string(try string()))
            // Not used by Syndicate: skipped by their size so the arguments after them stay aligned.
            case "h", "d", "t": _ = try take(8)
            case "c", "r", "m": _ = try take(4)
            case "S": _ = try string()
            case "b": _ = try take((Int(try uint32()) + 3) & ~3)
            case "T", "F", "N", "I": break
            // OSC 1.1 arrays carry no data of their own: Syndicate sends ColorPalette and others as "[iiii]", and the
            // arguments inside are read in order, flattened.
            case "[", "]": break
            // Its size is unknown, so nothing after it can be read.
            default: break tags
            }
        }
        return OSCMessage(address, arguments)
    }

    mutating func take(_ count: Int) throws(OSCError) -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count else { throw .truncated }
        let taken = bytes.prefix(count)
        bytes = bytes.dropFirst(count)
        return taken
    }

    mutating func uint32() throws(OSCError) -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() throws(OSCError) -> String {
        guard let end = bytes.firstIndex(of: 0) else { throw .truncated }
        let length = end - bytes.startIndex
        let value = String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
        _ = try take((length + 1 + 3) & ~3)
        return value
    }
}

private extension Array where Element == UInt8 {
    mutating func appendOSCString(_ string: String) {
        append(contentsOf: string.utf8)
        append(0)
        while count % 4 != 0 { append(0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }
}
