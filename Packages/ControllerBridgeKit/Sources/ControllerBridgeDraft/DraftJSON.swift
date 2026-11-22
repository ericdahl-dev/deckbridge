import Foundation

/// The draft profile as JSON that keeps keys in the order they were set, so the file reads like a bundled profile.
public indirect enum DraftJSON: Equatable, Sendable {
    case object([Pair])
    case array([DraftJSON])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public struct Pair: Equatable, Sendable {
        public var key: String
        public var value: DraftJSON
    }

    public subscript(key: String) -> DraftJSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    /// Sets the value at a dotted path ("mapping.notes.play"), making objects on the way; a key set again keeps its place.
    public mutating func set(_ path: String, _ value: DraftJSON) {
        set(path.split(separator: ".").map(String.init)[...], value)
    }

    private mutating func set(_ keys: ArraySlice<String>, _ value: DraftJSON) {
        guard let key = keys.first else { return self = value }
        var pairs: [Pair] = if case .object(let existing) = self { existing } else { [] }
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            pairs[index].value.set(keys.dropFirst(), value)
        } else {
            var child = DraftJSON.object([])
            child.set(keys.dropFirst(), value)
            pairs.append(Pair(key: key, value: child))
        }
        self = .object(pairs)
    }

    /// The value at a dotted path, if set.
    public func value(at path: String) -> DraftJSON? {
        path.split(separator: ".").reduce(Optional(self)) { $0?[String($1)] }
    }

    /// Pretty-printed with two-space indents, short arrays of numbers on one line, as the bundled profile is written.
    public func text(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            return "{\n" + pairs.map { "\(inner)\(Self.quoted($0.key)): \($0.value.text(indent: inner))" }.joined(separator: ",\n")
                + "\n\(indent)}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            if items.allSatisfy({ if case .int = $0 { true } else { false } }) {
                return "[" + items.map { $0.text() }.joined(separator: ", ") + "]"
            }
            return "[\n" + items.map { inner + $0.text(indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .string(let s): return Self.quoted(s)
        case .int(let n): return String(n)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    private static func quoted(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
