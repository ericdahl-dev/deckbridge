/// The Diagnostics window's tabs, in Syndicate-style words (#70).
public enum DiagnosticsTab: String, CaseIterable, Sendable {
    case monitor = "MIDI Monitor"
    case sweep = "LED Sweep"
    case osc = "OSC Log"
    /// The jog display simulator (#221): what the LC6000's jog display shows, drawn by the upload's renderer.
    case jog = "Jog display"

    /// The line shown in an empty list, so "nothing yet" never looks like "broken".
    /// What Save… suggests (#162), such as "DeckBridge OSC Log.txt". The app passes its display name.
    public func exportFileName(appName: String) -> String {
        "\(appName) \(rawValue).txt"
    }

    public func emptyText(controllerConnected: Bool) -> String {
        switch self {
        case .monitor: controllerConnected ? "Press any button on the controller." : "No controller connected."
        case .sweep: "Press Start Sweep. Watch the pads and ring."
        case .osc: "Nothing sent or received yet."
        case .jog: controllerConnected
            ? "Nothing on the jog display yet. Turn on Jog display in Settings, then load a track."
            : "No LC6000 connected. The jog display preview shows what DeckBridge sends it."
        }
    }

    /// The monitor's note about the notes the profile ignores (#103), so a quiet monitor doesn't look like a dead port.
    public static func hiddenNotesHint(_ notes: [Int]) -> String? {
        switch notes.count {
        case 0: nil
        case 1: "Note \(notes[0]), the controller's idle heartbeat, is hidden."
        default:
            "Notes " + notes.dropLast().map(String.init).joined(separator: ", ") + " and \(notes.last!), which the controller "
                + "sends on its own, are hidden."
        }
    }
}

/// Whether Start Sweep can run, and if not, why: the sweep lights the controller, so it needs its LED output.
public struct SweepAvailability: Equatable, Sendable {
    public var enabled: Bool
    public var reason: String?

    public init(enabled: Bool, reason: String?) {
        self.enabled = enabled
        self.reason = reason
    }

    public init(outputOpen: Bool) {
        self.init(enabled: outputOpen, reason: outputOpen ? nil : "No controller output. Plug in the controller.")
    }
}

/// Which way the OSC log's lines went (#218), by their "OSC <-" (from Syndicate) or "OSC ->" (to it) prefix.
public enum DiagnosticsDirection: String, CaseIterable, Sendable {
    case both = "In and out"
    case received = "In"
    case sent = "Out"
}

/// How the window narrows a Diagnostics list (#218): by text and direction. Display only.
public struct DiagnosticsFilter: Equatable, Sendable {
    /// Lines containing this, in any case; empty matches every line.
    public var text = ""
    /// OSC lines going this way; other lines (MIDI, the sweep) are never narrowed by it.
    public var direction = DiagnosticsDirection.both
    /// OSC lines for this deck (1–4): /Deck/N/, its mixer channel /Mixer/CHN/ and its filter /Mixer/filterN.
    /// Nil shows every deck. Other lines are never narrowed by it.
    public var deck: Int?

    public init(text: String = "", direction: DiagnosticsDirection = .both, deck: Int? = nil) {
        self.text = text
        self.direction = direction
        self.deck = deck
    }

    var isEmpty: Bool { text.isEmpty && direction == .both && deck == nil }

    func matches(_ line: DiagnosticsLines.Line) -> Bool {
        let text = line.text
        switch direction {
        case .both: break
        case .received: if text.hasPrefix("OSC -> ") { return false }
        case .sent: if text.hasPrefix("OSC <- ") { return false }
        }
        if let deck, text.hasPrefix("OSC "), !Self.address(of: text, isFor: deck) { return false }
        return self.text.isEmpty || text.localizedCaseInsensitiveContains(self.text)
    }

    /// "OSC <- /Syndicate/Mixer/CH2/Volume 1.0" is for deck 2: the address (before the arguments) has Deck/2,
    /// Mixer/CH2 or Mixer/filter2.<part>.
    private static func address(of text: String, isFor deck: Int) -> Bool {
        let address = text.dropFirst(7).split(separator: " ").first ?? ""
        let parts = address.split(separator: "/")
        for (index, part) in parts.enumerated() {
            if part == "Deck", index + 1 < parts.count, parts[index + 1] == "\(deck)" { return true }
            if part == "Mixer", index + 1 < parts.count {
                let next = parts[index + 1]
                if next == "CH\(deck)" || next.hasPrefix("filter\(deck).") { return true }
            }
        }
        return false
    }
}

/// The three Diagnostics lists. Each keeps its newest lines only, so a long set doesn't grow without bound.
/// Memory (#218): at most `limit` lines per list, plus `limit` streaming lines for the OSC log. A line is about 100 bytes
/// of text plus its fields, so a full OSC log holds roughly 2 × 20,000 × ~150 B ≈ 6 MB, and the three tabs under 15 MB.
public struct DiagnosticsLines: Equatable, Sendable {
    public static let limit = 20_000

    /// One line: the message, and for the monitor its mapping label, which the window colors when it's UNMAPPED.
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: Int
        public let message: String
        public let label: String
        public let isUnmapped: Bool
        /// The line exactly as the Python bridge printed it.
        public var text: String { message + label }
    }

    /// Syndicate's streaming feedback (#218), many lines a second each while playing; hidden by default.
    public var hideStreaming = true
    /// What the window narrows the lists to (#218). Display only: nothing is dropped from the history.
    public var filter = DiagnosticsFilter()
    /// While streaming values are shown, each stretch of them shows each address once, at its latest value, with how
    /// many arrived ("…/Position 48.91 ×3"), so a playing deck reads as a few updating lines (#218). Display only.
    public var collapseStreaming = true
    /// While paused, the lists show what they held when Pause was pressed, kept as it was (#319): capture carries on
    /// behind and keeps evicting, but not from the frozen copy (#218). The rings are values, so the copy costs one
    /// copy-on-write of each list that keeps growing.
    private var frozen: Frozen?
    private struct Frozen: Equatable, Sendable {
        var lists: [DiagnosticsTab: Ring]
        var streaming: Ring
    }
    public var isPaused: Bool { frozen != nil }

    public mutating func pause() { if frozen == nil { frozen = Frozen(lists: lists, streaming: streaming) } }
    public mutating func resume() { frozen = nil }
    private var lists: [DiagnosticsTab: Ring] = [:]
    /// The OSC tab's streaming lines, kept apart so their flood can't push the other lines out (#97).
    private var streaming: Ring
    private var nextID = 0
    /// Lines kept per list: `limit`, smaller in tests.
    private let capacity: Int

    public init(limit: Int = Self.limit) {
        capacity = limit
        streaming = Ring(capacity: limit)
    }

    public mutating func append(to tab: DiagnosticsTab, message: String, label: String = "", isUnmapped: Bool = false) {
        nextID += 1
        let line = Line(id: nextID, message: message, label: label, isUnmapped: isUnmapped)
        if tab == .osc, Self.isStreaming(line.text) {
            streaming.append(line)
            return
        }
        lists[tab, default: Ring(capacity: capacity)].append(line)
    }

    /// Empties one tab's list; the others stay.
    public mutating func clear(_ tab: DiagnosticsTab) {
        lists[tab] = Ring(capacity: capacity)
        if tab == .osc { streaming = Ring(capacity: capacity) }
        frozen?.lists[tab] = Ring(capacity: capacity)
        if tab == .osc { frozen?.streaming = Ring(capacity: capacity) }
    }

    /// What a tab shows, oldest first: its kept lines, through the streaming toggle and the filter.
    public func shown(_ tab: DiagnosticsTab) -> [Line] {
        let kept = kept(tab)
        let filtered = filter.isEmpty ? kept : kept.filter(filter.matches)
        guard tab == .osc, !hideStreaming, collapseStreaming else { return filtered }
        return Self.collapsed(filtered)
    }

    /// Each stretch of streaming lines (no other line between them) as one line per address, in the order each address
    /// last arrived, carrying its latest value and, past one, " ×count".
    private static func collapsed(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        out.reserveCapacity(lines.count)
        var stretch: [Substring: (line: Line, count: Int)] = [:]
        func flush() {
            for (line, count) in stretch.values.sorted(by: { $0.line.id < $1.line.id }) {
                out.append(count == 1 ? line : Line(id: line.id, message: line.message + " ×\(count)", label: line.label, isUnmapped: line.isUnmapped))
            }
            stretch.removeAll(keepingCapacity: true)
        }
        for line in lines {
            guard let address = streamingAddress(line.text) else {
                flush()
                out.append(line)
                continue
            }
            stretch[address] = (line, (stretch[address]?.count ?? 0) + 1)
        }
        flush()
        return out
    }

    /// How many shown lines the window draws (#218): one selectable text of 20,000 lines would stutter at 10 redraws a
    /// second. Copy and Save still take all of them.
    public static let drawLimit = 2_000

    /// What the window draws: the newest `drawLimit` shown lines, oldest first.
    public func drawn(_ tab: DiagnosticsTab) -> [Line] {
        Array(shown(tab).suffix(Self.drawLimit))
    }

    /// A tab's kept lines, with or without the streaming ones, oldest first.
    private func kept(_ tab: DiagnosticsTab) -> [Line] {
        let lists = frozen?.lists ?? lists, streaming = frozen?.streaming ?? streaming
        let list = lists[tab]?.lines ?? []
        guard tab == .osc, !hideStreaming else { return list }
        // Both kept lists, back in arrival order, and still no more than the limit.
        return Array(Self.merged(list, streaming.lines).suffix(capacity))
    }

    /// Two lists already in arrival order, merged into one in arrival order, in one pass.
    private static func merged(_ a: [Line], _ b: [Line]) -> [Line] {
        var out: [Line] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i].id < b[j].id { out.append(a[i]); i += 1 } else { out.append(b[j]); j += 1 }
        }
        out += a[i...]
        out += b[j...]
        return out
    }

    /// The newest `limit` lines in a fixed array, overwriting the oldest: appending costs the same at 20,000 as at 1.
    struct Ring: Equatable, Sendable {
        let capacity: Int
        private var storage: [Line] = []
        private var start = 0

        init(capacity: Int) { self.capacity = capacity }

        mutating func append(_ line: Line) {
            if storage.count < capacity {
                storage.append(line)
            } else {
                storage[start] = line
                start = (start + 1) % storage.count
            }
        }

        /// Oldest first.
        var lines: [Line] { start == 0 ? storage : Array(storage[start...] + storage[..<start]) }

        static func == (a: Ring, b: Ring) -> Bool { a.lines == b.lines }
    }

    /// What a tab shows, as plain text to copy or save (#162): one line each, ending in a newline. UNMAPPED keeps its
    /// words; the dot is only how the window draws it.
    public func plainText(_ tab: DiagnosticsTab) -> String {
        shown(tab).map { $0.text + "\n" }.joined()
    }

    /// Everything a tab has kept, as plain text for Save… (#218): streaming lines too, in arrival order, ignoring the
    /// filter, Pause and collapsing.
    public func historyText(_ tab: DiagnosticsTab) -> String {
        let list = lists[tab]?.lines ?? []
        let all = tab == .osc ? Self.merged(list, streaming.lines) : list
        return all.map { $0.text + "\n" }.joined()
    }

    /// The feedback Syndicate streams while playing, by the address's last part (#218): Position ~100/s per deck,
    /// BarRamp ~200/s, Meter ~100/s per channel (captures on #209), and the clocks and progress values like them.
    static let streamingNames: Set<String> = ["position", "barramp", "meter", "clock", "currentstep", "sampleprogress", "progress", "time"]

    /// "OSC <- /Syndicate/Deck/3/Position 48.91": feedback whose address ends in a streaming name. Only feedback: what
    /// DeckBridge sends is never a flood.
    private static func isStreaming(_ text: String) -> Bool { streamingAddress(text) != nil }

    /// The address of a streaming feedback line, or nil for any other line.
    private static func streamingAddress(_ text: String) -> Substring? {
        guard text.hasPrefix("OSC <- "), let address = text.dropFirst(7).split(separator: " ").first,
              let last = address.split(separator: "/").last, streamingNames.contains(last.lowercased()) else { return nil }
        return address
    }
}
