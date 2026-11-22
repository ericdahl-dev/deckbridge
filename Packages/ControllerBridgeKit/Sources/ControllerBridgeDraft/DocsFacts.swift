import Foundation

/// What a controller's public docs say (#189): a partial profile in the profile's own JSON shape, plus `sources`, one
/// citation per dotted key ("mapping.notes.sync": "FLX4 MIDI list p.1"). It fills what the capture didn't see.
public struct DocsFacts: Sendable {
    /// Each fact's dotted key and value, arrays as whole values.
    public var facts: [(key: String, value: DraftJSON)]
    public var sources: [String: String]

    public struct Invalid: Error, CustomStringConvertible {
        public var description: String
    }

    public init(facts: [(key: String, value: DraftJSON)] = [], sources: [String: String] = [:]) {
        self.facts = facts
        self.sources = sources
    }

    public init(json: Data) throws {
        guard let top = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Invalid(description: "The docs facts file isn't a JSON object like a profile.")
        }
        sources = (top["sources"] as? [String: String]) ?? [:]
        var facts: [(String, DraftJSON)] = []
        func walk(_ value: Any, _ path: String) throws {
            if let object = value as? [String: Any] {
                for key in object.keys.sorted() { try walk(object[key]!, path.isEmpty ? key : "\(path).\(key)") }
            } else {
                facts.append((path, try Self.value(value, at: path)))
            }
        }
        for key in top.keys.sorted() where key != "sources" { try walk(top[key]!, key) }
        self.facts = facts
    }

    private static func value(_ any: Any, at path: String) throws -> DraftJSON {
        switch any {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return .bool(number.boolValue)
        case let number as NSNumber:
            return number.doubleValue.rounded() == number.doubleValue && abs(number.doubleValue) < 1e15
                ? .int(number.intValue) : .double(number.doubleValue)
        case let text as String: return .string(text)
        case let list as [Any]: return .array(try list.map { try value($0, at: path) })
        case let object as [String: Any]:
            // Inside a list, such as midi.layers: kept whole, keys in the profile's order (channel before deck).
            let order = ["channel", "deck"]
            let keys = object.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            return .object(try keys.map { DraftJSON.Pair(key: $0, value: try value(object[$0]!, at: path)) })
        default: throw Invalid(description: "\(path): a value a profile can't hold.")
        }
    }
}
