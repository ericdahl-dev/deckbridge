import Foundation
@testable import ControllerBridgeCore
import Testing

/// The profile key table (#382): every key a mapping takes, declared once, with its kind, the LC6000's value, and its
/// range, choices or list length. Pinned here to what the checker does, through its public interface.
@Suite("Profile key table")
struct ProfileKeysTests {
    static let lc6000 = try! OrderedJSON(parsing: Mapping.defaultJSON())

    /// A partial mapping with `value` at `pattern` (a list item's index written `[]`), and the path a problem names.
    static func document(_ pattern: String, _ value: OrderedJSON) -> (json: Data, path: String) {
        var concrete = "", prefix = ""
        func build(_ parts: ArraySlice<Substring>) -> OrderedJSON {
            guard let part = parts.first else { return value }
            let isList = part.hasSuffix("[]")
            let name = isList ? String(part.dropLast(2)) : String(part)
            let listKey = prefix.isEmpty ? name : "\(prefix).\(name)"
            prefix += (prefix.isEmpty ? "" : ".") + part
            concrete += (concrete.isEmpty ? "" : ".") + name + (isList ? "[0]" : "")
            let inner = build(parts.dropFirst())
            // A list as long as its key needs (a color takes 3), so the length isn't what's refused.
            let length = max(1, ProfileKeys.key(listKey)?.count?.lowerBound ?? 1)
            return .object([(name, isList ? .array(Array(repeating: inner, count: length)) : inner)])
        }
        let doc = build(pattern.split(separator: ".")[...])
        return (Data(text(doc).utf8), concrete)
    }

    /// The checker's problems at `path`, leaving out a duplicate number (another key's concern).
    static func problems(_ pattern: String, _ value: OrderedJSON) -> [String] {
        let (json, path) = document(pattern, value)
        return Mapping.problems(in: json).filter { $0.hasPrefix("\(path): ") && !$0.contains(" is also ") }
    }

    static func number(_ n: Double, whole: Bool) -> OrderedJSON { .number(n, isInteger: whole) }

    /// JSON text for a value (the test's own writer).
    static func text(_ value: OrderedJSON) -> String {
        switch value {
        case .object(let pairs): "{" + pairs.map { "\"\($0.key)\": " + text($0.value) }.joined(separator: ", ") + "}"
        case .array(let items): "[" + items.map(text).joined(separator: ", ") + "]"
        case .string(let s): "\"\(s)\""
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case .number(let n, let whole): whole ? String(Int(n)) : String(n)
        }
    }

    @Test("Each key with an LC6000 value has the LC6000's value and kind, from the bundled profile")
    func lc6000Values() {
        for key in ProfileKeys.all {
            guard let expected = key.lc6000 else { continue }
            let found = Self.value(at: key.path, in: Self.lc6000)
            if key.kind == .object {
                if case .object? = found {} else { Issue.record("\(key.path): not an object in the LC6000's mapping") }
            } else {
                #expect(found == (try? OrderedJSON(parsing: Data(expected.utf8))), "\(key.path)")
            }
        }
    }

    @Test("Each key's kind is what the checker asks for: another kind is refused, naming the key's kind")
    func kinds() {
        for key in ProfileKeys.all {
            let wrong: OrderedJSON = key.kind == .bool ? .string("x") : .bool(true)
            let found = Self.problems(key.path, wrong)
            #expect(found.count == 1 && found[0].hasSuffix("expected \(key.kind.words), got \(Mapping.describe(wrong))"),
                    "\(key.path): \(found)")
        }
    }

    @Test("Each range's ends are allowed, and one past either end is refused")
    func ranges() {
        for key in ProfileKeys.all {
            guard let range = key.range else { continue }
            let whole = key.kind == .wholeNumber
            let step = whole ? 1.0 : 0.001
            #expect(Self.problems(key.path, Self.number(range.lowerBound, whole: whole)) == [], "\(key.path) low")
            #expect(Self.problems(key.path, Self.number(range.upperBound, whole: whole)) == [], "\(key.path) high")
            #expect(Self.problems(key.path, Self.number(range.lowerBound - step, whole: whole)).first?.contains("out of range") == true,
                    "\(key.path) below")
            #expect(Self.problems(key.path, Self.number(range.upperBound + step, whole: whole)).first?.contains("out of range") == true,
                    "\(key.path) above")
        }
    }

    @Test("Each key's choices are allowed, and anything else is refused")
    func choices() {
        for key in ProfileKeys.all {
            for choice in key.choices {
                #expect(Self.problems(key.path, .string(choice)) == [], "\(key.path) \(choice)")
            }
            if !key.choices.isEmpty {
                #expect(Self.problems(key.path, .string("nope")).first?.contains("isn't one of") == true, "\(key.path)")
            }
            for choice in key.numberChoices {
                #expect(Self.problems(key.path, Self.number(choice, whole: true)) == [], "\(key.path) \(choice)")
            }
            if !key.numberChoices.isEmpty {
                #expect(Self.problems(key.path, Self.number(1, whole: true)).first?.contains("isn't one of") == true, "\(key.path)")
            }
        }
    }

    @Test("Each list's length limits: the ends are allowed, one past either is refused")
    func counts() {
        for key in ProfileKeys.all {
            guard let count = key.count, let item = ProfileKeys.all.first(where: { $0.path == key.path + "[]" }) else { continue }
            let sample: OrderedJSON = item.kind == .object ? .object([]) : item.kind == .text ? .string(item.choices.first ?? "x")
                : Self.number(item.range?.lowerBound ?? 0, whole: true)
            func list(_ n: Int) -> OrderedJSON { .array(Array(repeating: sample, count: n)) }
            #expect(Self.problems(key.path, list(count.lowerBound)).filter { $0.contains("expected") } == [], "\(key.path) low")
            #expect(Self.problems(key.path, list(count.lowerBound - 1)).first?.contains("expected") == true, "\(key.path) below")
            if count.upperBound < Int.max {
                #expect(Self.problems(key.path, list(count.upperBound)).filter { $0.contains("expected") } == [], "\(key.path) high")
                #expect(Self.problems(key.path, list(count.upperBound + 1)).first?.contains("expected") == true, "\(key.path) above")
            }
        }
    }

    /// Every path in a document as a key pattern (list items as `[]`, each list's first item only).
    static func patterns(_ value: OrderedJSON, _ path: String = "") -> [String] {
        switch value {
        case .object(let pairs):
            return (path.isEmpty ? [] : [path]) + pairs.flatMap { patterns($0.value, path.isEmpty ? $0.key : "\(path).\($0.key)") }
        case .array(let items):
            return [path] + (items.first.map { patterns($0, path + "[]") } ?? [])
        default:
            return [path]
        }
    }

    @Test("Every path in the LC6000's mapping has a table entry, with an LC6000 value")
    func everyLC6000PathDeclared() {
        let paths = Self.patterns(Self.lc6000)
        #expect(paths.filter { ProfileKeys.key($0) == nil } == [])
        #expect(paths.filter { ProfileKeys.key($0)?.lc6000 == nil } == [])
    }

    @Test("Every entry with an LC6000 value is in its mapping; every optional one is a key the checker takes")
    func everyEntryReal() {
        let paths = Set(Self.patterns(Self.lc6000))
        for key in ProfileKeys.all where key.lc6000 != nil {
            #expect(paths.contains(key.path), "\(key.path)")
        }
        for key in ProfileKeys.all where key.lc6000 == nil {
            let (json, path) = Self.document(key.path, key.kind == .object ? .object([]) : key.kind == .list ? .array([]) : .null)
            #expect(!Mapping.problems(in: json).contains("\(path): unknown key"), "\(key.path)")
        }
    }

    @Test("A key the table doesn't have is an unknown key")
    func undeclaredIsUnknown() {
        for path in ["notes.dance", "mixer.crossfader", "notes.shifted.pads", "pads.mode_notes.jump", "midi.layers[].color"] {
            #expect(ProfileKeys.key(path) == nil, "\(path)")
            let (json, concrete) = Self.document(path, .number(1, isInteger: true))
            #expect(Mapping.problems(in: json).contains("\(concrete): unknown key"), "\(path)")
        }
    }

    /// The value at a key pattern in a document: a list item's `[]` is its first item.
    static func value(at pattern: String, in document: OrderedJSON) -> OrderedJSON? {
        var current: OrderedJSON? = document
        for part in pattern.split(separator: ".") {
            let isList = part.hasSuffix("[]")
            current = current?[String(isList ? part.dropLast(2) : part)]
            if isList {
                guard case .array(let items)? = current, let first = items.first else { return nil }
                current = first
            }
        }
        return current
    }
}

/// The decoder's defaults (#382): a key left out decodes to the table's fallback. Each case removes the key from (or,
/// for the mixer, adds a section without it to) the LC6000's mapping, decodes it, and reads the field back.
@Suite("Profile key table: the decoder's fallbacks")
struct ProfileKeyFallbackTests {
    static func decoded(without path: String, adding extra: [String: Any] = [:]) throws -> Mapping {
        var body = try JSONSerialization.jsonObject(with: Mapping.defaultJSON()) as! [String: Any]
        for (key, value) in extra { body[key] = value }
        let parts = path.split(separator: ".").map(String.init)
        func remove(_ object: [String: Any], _ parts: ArraySlice<String>) -> [String: Any] {
            var object = object
            guard let first = parts.first else { return object }
            if parts.count == 1 { object[first] = nil } else if let child = object[first] as? [String: Any] {
                object[first] = remove(child, parts.dropFirst())
            }
            return object
        }
        body = remove(body, parts[...])
        return try JSONDecoder().decode(Mapping.self, from: JSONSerialization.data(withJSONObject: body))
    }

    static func fallback<T: Decodable>(_ path: String, _ type: T.Type) throws -> T {
        let text = try #require(ProfileKeys.key(path)?.fallback, "\(path) has no fallback")
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    static func mixer() -> [String: Any] { ["mixer": ["volume": ["msb_cc": 100, "lsb_cc": 102], "meter": ["cc": 101, "steps": [0, 64]]]] }

    @Test("Each left-out key decodes to the table's fallback")
    func fallbacks() throws {
        #expect(try Self.decoded(without: "pads.roll_sizes").pads.rollSizes == Self.fallback("pads.roll_sizes", [String].self))
        #expect(try Self.decoded(without: "pads.mode_select").pads.modeSelect.rawValue == Self.fallback("pads.mode_select", String.self))
        #expect(try Self.decoded(without: "midi.ignore_notes").midi.ignoreNotes == Self.fallback("midi.ignore_notes", [Int].self))
        #expect(try Self.decoded(without: "midi.layers").midi.layers.isEmpty)
        #expect(try Self.fallback("midi.layers", [[String: Int]].self).isEmpty)
        #expect(try Self.decoded(without: "midi.encoder_format").midi.encoderFormat.rawValue
                == Self.fallback("midi.encoder_format", String.self))
        #expect(try Self.decoded(without: "pitch.bits").pitch?.bits == Self.fallback("pitch.bits", Int.self))
        #expect(try Self.decoded(without: "pitch.pickup").pitch?.pickup == Self.fallback("pitch.pickup", Bool.self))
        #expect(try Self.decoded(without: "pitch.pickup_tolerance").pitch?.pickupTolerance
                == Self.fallback("pitch.pickup_tolerance", Double.self))
        #expect(try Self.decoded(without: "leds.ring_follows_deck").leds.ringFollowsDeck == Self.fallback("leds.ring_follows_deck", Bool.self))
        #expect(try Self.decoded(without: "leds.mirror_shifted").leds.mirrorShifted == Self.fallback("leds.mirror_shifted", Bool.self))
        #expect(try Self.decoded(without: "leds.color_table").leds.colorTable == .rgb222)
        #expect(try Self.fallback("leds.color_table", String.self) == "rgb222")
        for level in ["full", "dim", "off"] {
            let levels = try Self.decoded(without: "leds.levels.\(level)").leds.levels
            let value = level == "full" ? levels.full : level == "dim" ? levels.dim : levels.off
            #expect(try value == Self.fallback("leds.levels.\(level)", Int.self), "\(level)")
        }
        #expect(try Self.decoded(without: "notes.shifted").notes.shifted == Self.fallback("notes.shifted", [String: Int].self))
        let mixer = try #require(try Self.decoded(without: "", adding: Self.mixer()).mixer)
        #expect(try mixer.volume?.bits == Self.fallback("mixer.volume.bits", Int.self))
        #expect(try mixer.meter?.holdMs == Self.fallback("mixer.meter.hold_ms", Int.self))
        #expect(try mixer.meter?.rateHz == Self.fallback("mixer.meter.rate_hz", Int.self))
        #expect(try mixer.pickup == Self.fallback("mixer.pickup", Bool.self))
        #expect(try mixer.pickupTolerance == Self.fallback("mixer.pickup_tolerance", Double.self))
    }
}
