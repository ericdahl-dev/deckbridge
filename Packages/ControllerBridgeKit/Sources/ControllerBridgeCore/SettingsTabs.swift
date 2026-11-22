/// The Settings window's tabs (#171), in toolbar order. ⌘1–4 pick them.
public enum SettingsTab: Int, CaseIterable, Hashable, Sendable {
    case controller = 1, decks, syndicate, general

    public var title: String {
        switch self {
        case .controller: "Controller"
        case .decks: "Decks"
        case .syndicate: "Syndicate"
        case .general: "General"
        }
    }

    /// The key that picks this tab with ⌘.
    public var shortcut: Character { Character(String(rawValue)) }

    /// The tab a field shows on.
    public init(field: SettingsField) {
        switch field {
        case .deck, .channel, .device: self = .controller
        case .deckColor: self = .decks
        case .host, .oscPort, .feedbackPort, .displayFeedHost, .displayFeedPort: self = .syndicate
        }
    }
}

/// What a refused Apply does in the tabbed window (#171): go to the leftmost tab with a problem and focus its first
/// bad field. A problem with no field, such as the bridge not running, leaves the tab alone.
public struct SettingsRefusal: Equatable, Sendable {
    public var tab: SettingsTab?
    public var focus: SettingsField?
    /// The footer's list: each field's problem after its tab's name, in tab order, then the problems with no field.
    public var footer: [String]

    /// What VoiceOver announces, so a jump to another tab is never a surprise (agent2's review of #171).
    public var announcement: String {
        "Settings not applied. " + footer.map { $0 + "." }.joined(separator: " ")
    }

    public init(fields: [SettingsProblem], other: [String] = []) {
        // A stable sort by tab: problems on one tab keep their form order.
        let sorted = fields.enumerated().sorted {
            (SettingsTab(field: $0.element.field).rawValue, $0.offset) < (SettingsTab(field: $1.element.field).rawValue, $1.offset)
        }.map(\.element)
        tab = sorted.first.map { SettingsTab(field: $0.field) }
        focus = sorted.first?.field
        footer = sorted.map { "\(SettingsTab(field: $0.field).title): \($0.message)" } + other
    }
}

/// How tall a Settings pane shows (#177): whole when it fits the room the screen leaves, else that room, scrolling.
/// The room never drops below 240 pt, so a pane can't collapse on a small screen.
public struct SettingsPaneFit: Equatable, Sendable {
    public static let minimumRoom = 240.0

    public var height: Double
    public var scrolls: Bool

    public init(height: Double, scrolls: Bool) {
        self.height = height
        self.scrolls = scrolls
    }

    public init(content: Double, room: Double) {
        let room = max(room, Self.minimumRoom)
        self.init(height: min(content, room), scrolls: content > room)
    }
}
