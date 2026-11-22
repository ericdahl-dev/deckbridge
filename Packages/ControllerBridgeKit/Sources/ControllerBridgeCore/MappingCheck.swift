import Foundation

extension Mapping {
    /// Every problem in a mapping body (a whole mapping, or a partial one to merge over the default), named by key
    /// path, in document order (#24). The bundled default mapping is the schema. An empty list means it's usable.
    /// `whole`: the mapping of a whole profile file (#251), checked for duplicates against its own keys only, not merged
    /// over the LC6000's, so a second controller doesn't collide with LC6000 buttons it doesn't have.
    public static func problems(in json: Data, whole: Bool = false) -> [String] {
        do {
            return problems(in: try OrderedJSON(parsing: json), whole: whole)
        } catch {
            return ["\(error)"]
        }
    }

    /// `schema` is the body of the profile being changed (#94); by default the bundled LC6000's.
    static func problems(in document: OrderedJSON, schema given: OrderedJSON? = nil, whole: Bool = false) -> [String] {
        guard let schema = given ?? (try? OrderedJSON(parsing: defaultJSON())) else { return ["The default mapping can't be read."] }
        if let problem = kindProblem(document, expected: schema) { return ["mapping: \(problem)"] }
        var out: [String] = []
        walk(document, schema: schema, path: "", into: &out)
        let checked = known(document, schema: schema)
        let merged = whole ? checked : merge(schema, checked)
        out += duplicates(in: merged, written: Set(leafPaths(document)))
        out += arrowClashes(in: merged, written: Set(leafPaths(document)))
        // Document order: by where the problem's path first appears in what the user wrote.
        let order = Dictionary(leafPaths(document).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return out.enumerated().sorted { a, b in
            let (pa, pb) = (order[path(of: a.element)] ?? Int.max, order[path(of: b.element)] ?? Int.max)
            return pa == pb ? a.offset < b.offset : pa < pb
        }.map(\.element)
    }

    private static func path(of problem: String) -> String { String(problem.prefix { $0 != ":" }) }

    /// Every path in a document, objects and lists included, in document order.
    private static func leafPaths(_ value: OrderedJSON, _ path: String = "") -> [String] {
        switch value {
        case .object(let pairs):
            return (path.isEmpty ? [] : [path]) + pairs.flatMap { leafPaths($0.value, path.isEmpty ? $0.key : "\(path).\($0.key)") }
        case .array(let items):
            return [path] + items.enumerated().flatMap { leafPaths($1, "\(path)[\($0)]") }
        default:
            return [path]
        }
    }

    /// The document without unknown keys or values of the wrong kind, already reported, so they can't also show
    /// up as duplicates.
    private static func known(_ value: OrderedJSON, schema: OrderedJSON, path: String = "") -> OrderedJSON {
        switch (value, schema) {
        case let (.object(pairs), .object):
            return .object(pairs.compactMap { pair in
                let childPath = path.isEmpty ? pair.key : "\(path).\(pair.key)"
                guard let given = schema[pair.key] ?? optionalKey(childPath) else { return nil }
                let expected = alternative(pair.value, at: childPath) ?? given
                guard kindProblem(pair.value, expected: kind(at: childPath, value: pair.value, schema: given)) == nil else { return nil }
                return (pair.key, known(pair.value, schema: expected, path: childPath))
            })
        case let (.array(items), .array(schemaItems)):
            guard let element = schemaItems.first else { return value }
            // Null, not dropped, so the other items keep their indices.
            return .array(items.enumerated().map { index, item in
                kindProblem(item, expected: kind(at: "\(path)[\(index)]", value: item, schema: element)) == nil ? item : .null
            })
        default:
            return value
        }
    }

    /// The Python merge on ordered JSON: objects merge key by key, keeping the base's order; anything else replaces.
    static func merge(_ base: OrderedJSON, _ override: OrderedJSON) -> OrderedJSON {
        guard case .object(var pairs) = base, case .object(let overrides) = override else { return override }
        for (key, value) in overrides {
            if let index = pairs.firstIndex(where: { $0.key == key }) {
                pairs[index].value = merge(pairs[index].value, value)
            } else {
                pairs.append((key, value))
            }
        }
        return .object(pairs)
    }

    /// Where each kind of MIDI number is used. Notes and CCs are separate namespaces; LED notes aren't checked, as
    /// an LED may share its button's note.
    private static func uses(_ merged: OrderedJSON) -> (notes: [(String, Double)], ccs: [(String, Double)]) {
        var notes: [(String, Double)] = [], ccs: [(String, Double)] = []
        // With per-mode pad notes (#225), the pads send those; notes.pads only counts them (#322).
        let hasModeNotes = merged["pads"]?["mode_notes"] != nil
        for path in leafPaths(merged) {
            guard case .number(let n, _)? = value(at: path, in: merged) else { continue }
            let pattern = path.replacingOccurrences(of: #"\[\d+\]"#, with: "[]", options: .regularExpression)
            if pattern == "notes.pads[]", hasModeNotes { continue }
            if pattern.hasPrefix("notes.") || pattern.hasPrefix("pads.mode_notes.") || pattern == "needle.touch_note" || ProfileKeys.mixerNotes.map({ "mixer.\($0)" }).contains(pattern) {
                notes.append((path, n))
            } else if ["jog.msb_cc", "jog.lsb_cc", "pitch.msb_cc", "pitch.lsb_cc", "needle.msb_cc", "needle.lsb_cc", "browse.select_turn_cc",
                       "browse.auto_loop_size_cc", "jog.relative_cc", "jog.relative_edge_cc"].contains(pattern)
                // A mixer fader's CCs are inputs too; the meter's CC is an output, so it can't clash with one (#207).
                || ProfileKeys.mixerControls.contains(where: { pattern == "mixer.\($0).msb_cc" || pattern == "mixer.\($0).lsb_cc" }) {
                ccs.append((path, n))
            }
        }
        return (notes, ccs)
    }

    /// A number used twice in one namespace, reported at the path the user wrote (the later one if they wrote both).
    private static func duplicates(in merged: OrderedJSON, written: Set<String>) -> [String] {
        let (notes, ccs) = uses(merged)
        let (deck, pads) = channels(merged)
        // A note can arrive on the pads' channels or the deck's (#251): two notes collide only where those meet.
        let noteChannels = notes.map { use in
            (path: use.0, n: use.1, channels: use.0.hasPrefix("notes.pads[") || use.0.hasPrefix("pads.mode_notes.") ? pads : deck)
        }
        let anyChannel = ccs.map { (path: $0.0, n: $0.1, channels: deck) }
        let layers = layerChannels(merged).map { (path: $0.0, n: $0.1, channels: Set([0.0])) }
        var out: [String] = []
        for (kind, list) in [("note", noteChannels), ("CC", anyChannel), ("channel", layers)] {
            var groups: [(n: Double, channels: Set<Double>, paths: [String])] = []
            for use in list {
                if let index = groups.firstIndex(where: { $0.n == use.n && !$0.channels.isDisjoint(with: use.channels) }) {
                    groups[index].paths.append(use.path)
                    groups[index].channels.formUnion(use.channels)
                } else {
                    groups.append((use.n, use.channels, [use.path]))
                }
            }
            for group in groups where group.paths.count > 1 {
                guard let at = group.paths.last(where: written.contains) else { continue }
                let others = group.paths.filter { $0 != at }.joined(separator: " and ")
                out.append("\(at): \(kind) \(Int(group.n)) is also \(others)")
            }
        }
        return out
    }

    /// A pitch arrow (#475) on a note another light uses: the center light, the ring, the other arrow, or a deck
    /// button (which lights its own note). Other LED notes may share a button's note, so only the arrows are checked.
    private static func arrowClashes(in merged: OrderedJSON, written: Set<String>) -> [String] {
        let arrows = ["leds.pitch_arrow_back", "leds.pitch_arrow_forward"]
        func number(_ path: String) -> Double? { if case .number(let n, _)? = value(at: path, in: merged) { n } else { nil } }
        let buttons = uses(merged).notes.filter { !$0.0.hasPrefix("notes.pads[") && !$0.0.hasPrefix("pads.mode_notes.") }
        let lights = (["leds.pitch_center", "leds.ring"] + arrows).compactMap { path in number(path).map { (path, $0) } } + buttons
        return arrows.filter(written.contains).compactMap { arrow in
            guard let n = number(arrow) else { return nil }
            let others = lights.filter { $0.0 != arrow && $0.1 == n }.map(\.0)
            return others.isEmpty ? nil : "\(arrow): note \(Int(n)) is also \(others.joined(separator: " and "))"
        }
    }

    /// The channels the deck's buttons arrive on (midi.channel and every layer's) and the pads' (pads.channel, or each
    /// layer's pad_channel, else the deck's; pads.channel only when no layer sets its own; and the Shift pads' channels) (#224, #251, #323, #343).
    private static func channels(_ merged: OrderedJSON) -> (deck: Set<Double>, pads: Set<Double>) {
        func number(_ value: OrderedJSON?) -> Double? { if case .number(let n, _)? = value { n } else { nil } }
        var deck = Set([number(merged["midi"]?["channel"]) ?? 1])
        var pads: Set<Double> = []
        let padChannel = number(merged["pads"]?["channel"])
        if case .array(let layers)? = merged["midi"]?["layers"], !layers.isEmpty {
            // As the Coordinator runs them (#323): once a layer sets a pad channel, the top-level one isn't inherited.
            let anyOwn = layers.contains { number($0["pad_channel"]) != nil }
            for layer in layers {
                guard let channel = number(layer["channel"]) else { continue }
                deck.insert(channel)
                pads.insert(number(layer["pad_channel"]) ?? (anyOwn ? channel : padChannel ?? channel))
            }
        }
        if pads.isEmpty { pads = padChannel.map { [$0] } ?? deck }
        // The Shift pads' channels (#324, #343): the pads' notes arrive there too. The top-level one only when no layer
        // sets its own, as for pad_channel.
        let shifted = number(merged["pads"]?["shifted_channel"])
        if case .array(let layers)? = merged["midi"]?["layers"], layers.contains(where: { number($0["shifted_pad_channel"]) != nil }) {
            for layer in layers { if let channel = number(layer["shifted_pad_channel"]) { pads.insert(channel) } }
        } else if let shifted {
            pads.insert(shifted)
        }
        return (deck, pads)
    }

    /// Each layer's channel: two layers can't share one (#79).
    private static func layerChannels(_ merged: OrderedJSON) -> [(String, Double)] {
        guard case .array(let layers)? = merged["midi"]?["layers"] else { return [] }
        return layers.indices.compactMap { index in
            guard case .number(let channel, _)? = layers[index]["channel"] else { return nil }
            return ("midi.layers[\(index)].channel", channel)
        }
    }

    private static func value(at path: String, in document: OrderedJSON) -> OrderedJSON? {
        var current: OrderedJSON? = document
        for part in path.split(separator: ".") {
            var name = Substring(part)
            var indices: [Int] = []
            while let open = name.lastIndex(of: "["), name.hasSuffix("]") {
                indices.insert(Int(name[name.index(after: open)..<name.index(before: name.endIndex)])!, at: 0)
                name = name[..<open]
            }
            current = current?[String(name)]
            for i in indices {
                guard case .array(let items)? = current, items.indices.contains(i) else { return nil }
                current = items[i]
            }
        }
        return current
    }

    /// The default mapping body, the schema every import is checked against.
    public static func defaultMappingJSON() throws -> Data { try defaultJSON() }

    /// A generic walker over the key table (#382): each value's kind, then its range, choices or length, come from the
    /// table; `schema` (the LC6000's body, or the profile's being changed, #94) only says which keys are there, with
    /// the table's optional keys besides.
    private static func walk(_ value: OrderedJSON, schema given: OrderedJSON, path: String, into out: inout [String]) {
        let schema = alternative(value, at: path) ?? given
        if let problem = kindProblem(value, expected: kind(at: path, value: value, schema: given)) {
            out.append("\(path): \(problem)")
            return
        }
        if let problem = valueProblem(value, at: path) {
            out.append("\(path): \(problem)")
            return
        }
        switch (value, schema) {
        case let (.object(pairs), _):
            for (key, child) in pairs {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                guard let expected = schema[key] ?? optionalKey(childPath) else {
                    out.append("\(childPath): unknown key")
                    continue
                }
                walk(child, schema: expected, path: childPath, into: &out)
            }
        case let (.array(items), .array(schemaItems)):
            guard let element = schemaItems.first else { return }
            for (index, item) in items.enumerated() {
                walk(item, schema: element, path: "\(path)[\(index)]", into: &out)
            }
        default:
            break
        }
    }

    /// What's wrong with a value's kind, measured against the default's value at the same path; nil when it fits.
    static func kindProblem(_ value: OrderedJSON, expected: OrderedJSON) -> String? {
        let fits = switch (value, expected) {
        case (.object, .object), (.array, .array), (.string, .string), (.bool, .bool): true
        // A setting whose default is whole takes only whole numbers (2.0 is whole); a fractional one takes any.
        case let (.number(n, _), .number(_, isInteger)): !isInteger || n.rounded() == n
        default: false
        }
        guard !fits else { return nil }
        let wanted = switch expected {
        case .object: "an object"
        case .array: "a list"
        case .string: "text"
        case .bool: "true or false"
        case .number(_, let isInteger): isInteger ? "a whole number" : "a number"
        case .null: "nothing"
        }
        return "expected \(wanted), got \(describe(value))"
    }

    /// Keys that take another kind than the default's too: the color table is "rgb222" or a list of entries (#197),
    /// whose entries are the table's `leds.color_table[]` keys.
    private static func alternative(_ value: OrderedJSON, at path: String) -> OrderedJSON? {
        guard path == "leds.color_table", let entry = example("leds.color_table[]") else { return nil }
        let other = OrderedJSON.array([entry])
        return kindProblem(value, expected: other) == nil ? other : nil
    }

    /// An optional key's expected kind (one the LC6000's mapping leaves out), from the key table, by its path with a
    /// list item's index written `[]`.
    private static func optionalKey(_ path: String) -> OrderedJSON? {
        let pattern = keyPattern(path)
        guard let key = ProfileKeys.key(pattern), key.lc6000 == nil else { return nil }
        return example(pattern)
    }

    /// The kind a value at `path` must have: the color table's other form when it's that, else the key table's, else
    /// (the mapping itself, at the root) the schema's.
    private static func kind(at path: String, value: OrderedJSON, schema: OrderedJSON) -> OrderedJSON {
        alternative(value, at: path) ?? (path.isEmpty ? nil : example(keyPattern(path))) ?? schema
    }

    /// A path with each list index written `[]`, as the key table has it.
    static func keyPattern(_ path: String) -> String {
        path.replacingOccurrences(of: #"\[\d+\]"#, with: "[]", options: .regularExpression)
    }

    /// An example value of the key's kind, with an object's children and a list's item from the table; built once.
    static func example(_ pattern: String) -> OrderedJSON? { examples[pattern] }
    private static let examples: [String: OrderedJSON] = Dictionary(
        ProfileKeys.all.compactMap { key in buildExample(key.path).map { (key.path, $0) } }, uniquingKeysWith: { first, _ in first }
    )

    private static func buildExample(_ pattern: String) -> OrderedJSON? {
        guard let key = ProfileKeys.key(pattern) else { return nil }
        switch key.kind {
        case .wholeNumber: return .number(0, isInteger: true)
        case .number: return .number(0, isInteger: false)
        case .bool: return .bool(false)
        case .text: return .string("")
        case .list: return .array(buildExample(pattern + "[]").map { [$0] } ?? [])
        case .object:
            let children = ProfileKeys.all.filter { child in
                child.path.hasPrefix(pattern + ".") && !child.path.dropFirst(pattern.count + 1).contains(".")
                    && !child.path.hasSuffix("[]")
            }
            return .object(children.compactMap { child in
                buildExample(child.path).map { (String(child.path.dropFirst(pattern.count + 1)), $0) }
            })
        }
    }

    /// A range, count or choice problem with a value of the right kind, from the key table; nil when it's fine.
    private static func valueProblem(_ value: OrderedJSON, at path: String) -> String? {
        guard let key = ProfileKeys.key(keyPattern(path)) else { return nil }
        switch value {
        case .number(let n, _):
            if !key.numberChoices.isEmpty, !key.numberChoices.contains(n) {
                return "\(describe(value)) isn't one of \(key.numberChoices.map { String(Int($0)) }.joined(separator: ", "))"
            }
            if let range = key.range, !range.contains(n) {
                return "\(describe(value)) is out of range, expected \(Int(range.lowerBound))-\(Int(range.upperBound))"
            }
        case .array(let items):
            return key.countProblem(items.count)
        case .string(let text):
            if !key.choices.isEmpty, !key.choices.contains(text) {
                return "\(describe(value)) isn't one of \(key.choices.joined(separator: ", "))"
            }
        default:
            break
        }
        return nil
    }

    /// A value as the user wrote it, for a problem message.
    static func describe(_ value: OrderedJSON) -> String {
        switch value {
        case .object: "an object"
        case .array: "a list"
        case .string(let text): "\"\(text)\""
        case .bool(let flag): flag ? "true" : "false"
        case .null: "null"
        case .number(let n, _): n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
        }
    }
}

extension CaseIterable where Self: RawRepresentable, RawValue == String {
    static var allRawValues: [String] { allCases.map(\.rawValue) }
}
