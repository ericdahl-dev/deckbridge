/// What the bridge knows about itself, as the menu needs it. The app fills this from the Coordinator's status and the
/// feedback listener; it has no CoreMIDI or SwiftUI types, so the wording can be tested here.
/// Why a controller disconnected, as the panel needs it (#91). The app maps Core's DisconnectReason onto this, one to one.
extension BridgeState {
    /// Which part of the bridge couldn't start (#88), so the help gives the right fix.
    public enum StopReason: Equatable, Sendable {
        /// CoreMIDI couldn't start.
        case midi
        /// The OSC sender couldn't open, such as for a Syndicate host that can't be reached.
        case oscSender
        /// The controller profiles couldn't load.
        case profiles

        /// Short, for the header.
        var short: String {
            switch self {
            case .midi: "Couldn't open MIDI"
            case .oscSender: "Couldn't reach Syndicate"
            case .profiles: "Couldn't load profiles"
            }
        }
    }

    public enum Disconnect: Equatable, Sendable {
        case unplugged, sendFailed, inputFailed, deviceChanged, removed, stopped
    }
}

extension BridgeState.Controller {
    /// The panel's controller state from what Core reports (#91): connected; unplugged, failed or waiting according to
    /// why it last disconnected, keeping its name; or never connected.
    public init(connected: Bool, profile: String?, lastProfile: String?, lastDisconnect: BridgeState.Disconnect?) {
        if connected {
            self = .connected(profile: profile ?? lastProfile ?? "Controller")
            return
        }
        switch lastDisconnect {
        case .unplugged: self = .unplugged(profile: lastProfile)
        case .sendFailed, .inputFailed: self = .failed(profile: lastProfile)
        case .deviceChanged: self = .waiting(profile: lastProfile)
        case .removed, .stopped, nil: self = .notConnected
        }
    }
}

/// A Syndicate subscription that's off (#211): its name on Syndicate's OSC FEEDBACK screen, and what breaks without it.
public struct MissingSubscription: Equatable, Sendable {
    public var name: String
    public var breaks: String

    public init(name: String, breaks: String) {
        self.name = name
        self.breaks = breaks
    }
}

public struct BridgeState: Equatable, Sendable {
    public enum Controller: Equatable, Sendable {
        case connected(profile: String)
        /// Connected earlier this session, now gone (#66): orange, so an unplug mid-set is noticed.
        case unplugged(profile: String?)
        /// Never connected since launch.
        case notConnected
        /// Connected, then sending or reading failed (#91): orange MIDI ERROR, not UNPLUGGED.
        case failed(profile: String?)
        /// Settings chose other devices, and they aren't there (yet) (#91): gray WAITING.
        case waiting(profile: String?)
    }

    public enum Feedback: Equatable, Sendable {
        case starting
        case live(port: Int)
        /// Listening, but Syndicate hasn't answered since launch (#21).
        case waiting(port: Int)
        /// Syndicate answers, but with no deck info: its OSC FEEDBACK subscriptions are off (#150).
        case noDeckData(port: Int)
        /// Listening, but Syndicate stopped answering (#21).
        case stopped(port: Int)
        /// Another app holds the port, so no feedback arrives.
        case portInUse(port: Int)
        /// Any other listener failure. The reason goes in the diagnostics (#26), not the status line.
        case failed
    }

    public var controller: Controller
    public var feedback: Feedback
    public var deck: Int
    /// The bridge couldn't start at all; the reason goes in the panel and the diagnostics (#26).
    public var stopped: Bool
    /// When Syndicate's feedback last stopped (#21), as the time to show, such as "21:14".
    public var lastDropout: String?

    /// The deck is Syndicate's tempo master (#53). Not a problem, so it never changes the icon.
    public var master: Bool
    /// The built-in demo controller is running (#64), not real hardware.
    public var demo: Bool
    /// The last connect, disconnect or unplug, for the header's subtitle.
    public var lastEvent: String?
    /// When `stopped`, which part failed (#88).
    public var stopReason: StopReason
    /// Further controllers after the first (#25), each with its own deck and last event.
    public var others: [ControllerEntry]

    public struct ControllerEntry: Equatable, Sendable {
        public var controller: Controller
        public var deck: Int
        public var lastEvent: String?
        /// The controller follows its own deck layers (#79), so `deck` is its active layer's.
        public var followsLayers: Bool

        public init(controller: Controller, deck: Int, lastEvent: String? = nil, followsLayers: Bool = false) {
            self.controller = controller
            self.deck = deck
            self.lastEvent = lastEvent
            self.followsLayers = followsLayers
        }
    }

    /// The first controller follows its own deck layers (#79).
    public var followsLayers = false
    /// The subscriptions a loaded deck's feedback lacked (#150, #211), with what each breaks.
    public var missingSubscriptions: [MissingSubscription] = []
    /// The subscriptions the profile needs, by Syndicate's names, for the "turn them on" help (#211).
    public var requiredSubscriptions: [String] = []
    /// Another DJ app holds the LC6000 as its host (#333).
    public var otherHost = false

    public init(controller: Controller, feedback: Feedback, deck: Int, stopped: Bool = false, lastDropout: String? = nil,
                master: Bool = false, demo: Bool = false, lastEvent: String? = nil, others: [ControllerEntry] = [],
                stopReason: StopReason = .midi, followsLayers: Bool = false, missingSubscriptions: [MissingSubscription] = [],
                requiredSubscriptions: [String] = []) {
        self.missingSubscriptions = missingSubscriptions
        self.requiredSubscriptions = requiredSubscriptions
        self.stopReason = stopReason
        self.followsLayers = followsLayers
        self.demo = demo
        self.lastEvent = lastEvent
        self.others = others
        self.controller = controller
        self.feedback = feedback
        self.deck = deck
        self.stopped = stopped
        self.lastDropout = lastDropout
        self.master = master
    }
}

/// One status light: a dot in `tone`'s color, a label, and a word. The word carries the meaning on its own.
public struct StatusLight: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case live
        /// Nothing wrong, nothing happening: gray.
        case idle
        /// Needs a look, like Syndicate's orange: not broken.
        case attention
        /// Something is broken and the DJ must act: muted red.
        case error
    }

    /// Which light this is, so views and the spoken text never match on display words (#171).
    public enum Kind: Equatable, Sendable {
        case controller, feedback, bridge, demo, tempo
        /// A MIDI device, named as the system names it.
        case device
    }

    public var label: String
    public var word: String
    public var tone: Tone
    public var kind: Kind

    /// The kind is always given, never read from the words: a device can be named anything (#171).
    public init(label: String, word: String, tone: Tone, kind: Kind) {
        self.label = label
        self.word = word
        self.tone = tone
        self.kind = kind
    }

    /// A MIDI source that no controller profile matches (#43): listed, not bridged.
    public init(unmatchedDevice name: String) {
        self.init(label: name, word: "No profile", tone: .attention, kind: .device)
    }
}

/// One part of the status bar: "LABEL ● WORD", or a bare word such as "DECK [1]" or "MASTER".
public struct StatusLinePart: Equatable, Sendable {
    public var label: String?
    public var word: String
    public var tone: StatusLight.Tone

    public init(label: String?, word: String, tone: StatusLight.Tone) {
        self.label = label
        self.word = word
        self.tone = tone
    }

    public var text: String { label.map { "\($0) ● \(word)" } ?? word }
}

/// The panel's header: what controller this is, and what last happened to it.
public struct StatusHeader: Equatable, Sendable {
    public var title: String
    public var subtitle: String?

    public init(title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// One controller in the panel: who it is, whether it's connected, and its deck.
public struct ControllerBlock: Equatable, Sendable {
    public var header: StatusHeader
    public var light: StatusLight
    public var deck: Int
    /// The controller picks the deck itself, through its own layers (#79): the panel shows it, not a picker.
    public var followsLayers: Bool
    /// What VoiceOver says for the whole block, so two blocks with the same name can be told apart (#89).
    public var accessibilityLabel: String

    public init(header: StatusHeader, light: StatusLight, deck: Int, followsLayers: Bool = false, accessibilityLabel: String? = nil) {
        self.header = header
        self.light = light
        self.deck = deck
        self.followsLayers = followsLayers
        self.accessibilityLabel = accessibilityLabel ?? "Controller, \(header.title)"
    }

    /// Said beside the deck when the controller's layers pick it.
    public var deckNote: String? { followsLayers ? "Following controller layers" : nil }
}

/// A small caption over a value, such as LAST DROPOUT over 21:14. The caption is natural case; the view uppercases it.
public struct CaptionedValue: Equatable, Sendable {
    public var caption: String
    public var value: String

    public init(caption: String, value: String) {
        self.caption = caption
        self.value = value
    }
}

/// The deck picker: usable, shown but off with a reason, or not shown.
public enum DeckPickerState: Equatable, Sendable {
    case enabled
    case disabled(reason: String)
    case hidden
}

/// The menu-bar icon's state dot.
public enum IconState: Equatable, Sendable {
    case ok
    case attention
    case error
}

/// The menu's lights, its Syndicate-style status line and the icon state, in Syndicate's vocabulary.
public struct StatusPresentation: Equatable, Sendable {
    public var lights: [StatusLight]
    public var line: String
    /// The panel's header: the first controller's name and its last event (#66).
    public var header: StatusHeader
    /// One block per controller: its header, its CONTROLLER light and its deck (#66, #25).
    public var blocks: [ControllerBlock]
    /// The parts of `line`, for the status bar to draw in their tones.
    public var lineParts: [StatusLinePart]
    public var icon: IconState
    /// The orange MASTER light, apart from `lights` so it never counts toward the icon (#53).
    public var master: StatusLight?
    /// LAST DROPOUT and its time, once Syndicate's feedback has stopped at least once (#21, #66).
    public var lastDropout: CaptionedValue?
    /// Whether Quit asks before quitting (#66).
    public var quitAsks: Bool
    /// Whether the panel offers the demo toggle: not while stopped, when there's nothing to switch it on with (#88).
    public var showsDemoToggle: Bool
    /// Whether the deck picker can be used, and why not (#90).
    public var deckPicker: DeckPickerState

    /// How many characters the panel's status bar holds without truncating (360 pt, 10 pt semibold caps).
    public static let lineBudget = 56

    public init(_ state: BridgeState, lineBudget: Int = StatusPresentation.lineBudget) {
        let controller = Self.light(for: state.controller)
        blocks = ([BridgeState.ControllerEntry(controller: state.controller, deck: state.deck, lastEvent: state.lastEvent,
                                               followsLayers: state.followsLayers)] + state.others)
            .map {
                ControllerBlock(header: Self.header(for: $0.controller, lastEvent: $0.lastEvent), light: Self.light(for: $0.controller),
                                deck: $0.deck, followsLayers: $0.followsLayers)
            }
        // Several controllers (#89): numbered for VoiceOver, and on screen when their names repeat.
        if blocks.count > 1 {
            let titles = blocks.map(\.header.title)
            for index in blocks.indices {
                let title = titles[index]
                blocks[index].accessibilityLabel = "Controller \(index + 1), \(title)"
                if titles.filter({ $0 == title }).count > 1 { blocks[index].header.title = "\(title) \(index + 1)" }
            }
        }
        // A stopped bridge: the header names the bridge's problem, not the controller (#88). The panel draws the
        // first block's header, so it says it there too.
        if state.stopped { blocks[0].header = StatusHeader(title: "Bridge stopped", subtitle: state.stopReason.short) }
        header = blocks[0].header
        showsDemoToggle = !state.stopped
        let feedback: StatusLight = switch state.feedback {
        case .starting: StatusLight(label: "Feedback", word: "Starting", tone: .idle, kind: .feedback)
        case .live: StatusLight(label: "Feedback", word: "Live", tone: .live, kind: .feedback)
        case .noDeckData: StatusLight(label: "Feedback", word: "No deck data", tone: .attention, kind: .feedback)
        case .waiting: StatusLight(label: "Feedback", word: "Waiting", tone: .idle, kind: .feedback)
        case .stopped: StatusLight(label: "Feedback", word: "Dropped", tone: .attention, kind: .feedback)
        case .portInUse(let port): StatusLight(label: "Feedback", word: "Port \(port) in use", tone: .error, kind: .feedback)
        case .failed: StatusLight(label: "Feedback", word: "Failed", tone: .error, kind: .feedback)
        }
        // A bridge that couldn't start has nothing starting or connecting: the BRIDGE light alone tells the truth (#66).
        lights = state.stopped ? [StatusLight(label: "Bridge", word: "Stopped", tone: .error, kind: .bridge)]
            // Orange and first, and it keeps the icon on attention: DEMO must never be mistaken for real hardware.
            : (state.demo ? [StatusLight(label: "Demo", word: "Controller", tone: .attention, kind: .demo)] : []) + [controller, feedback]
        // Stopped, nothing runs: no MASTER either (#88).
        master = state.master && !state.stopped ? StatusLight(label: "Tempo", word: "Master", tone: .attention, kind: .tempo) : nil
        // The status bar: each light, then the deck, then MASTER, cut to whole parts that fit (#66).
        // With several controllers, the line's controller part is the worst of them, counted, and the decks rank
        // with it, ahead of FEEDBACK, which the lights above still show (#89).
        let several = blocks.count > 1
        let summary = Self.summary(of: blocks.map(\.light))
        let parts = lights.map { light in
            let part = several && light == controller ? summary : StatusLinePart(label: light.label, word: light.word, tone: light.tone)
            return (part, Self.priority(of: light, controller: controller))
        }
            + [several
                ? (StatusLinePart(label: nil, word: "Decks " + blocks.map { "\($0.deck)" }.joined(separator: " "), tone: .idle), 1)
                : (StatusLinePart(label: nil, word: "Deck [\(blocks[0].deck)]", tone: .idle), 4)]
            + (master != nil ? [(StatusLinePart(label: nil, word: "Master", tone: .attention), 3)] : [])
        lineParts = Self.fit(parts, budget: lineBudget)
        line = lineParts.map(\.text).joined(separator: Self.separator)
        // Every controller counts: an unplugged second one needs a look too.
        let allLights = lights + blocks.dropFirst().map(\.light)
        icon = if allLights.contains(where: { $0.tone == .error }) { .error }
            else if allLights.allSatisfy({ $0.tone == .live }) { .ok }
            else { .attention }
        lastDropout = state.lastDropout.map { CaptionedValue(caption: "Last dropout", value: $0) }
        // Quitting stops a working set only while feedback is live, so that's when Quit asks first (#66).
        switch state.feedback {
        case .live, .noDeckData: quitAsks = true
        default: quitAsks = false
        }
        // In demo mode a click would be held for the real controller and jump its deck later, unasked (#90).
        deckPicker = state.stopped ? .hidden
            : state.demo ? .disabled(reason: "Demo controller is on, so the deck stays put.") : .enabled
    }

    static let separator = " · "

    /// Several controllers as one line part: the worst state, with how many are in it, such as "1 UNPLUGGED".
    static func summary(of lights: [StatusLight]) -> StatusLinePart {
        let severity: [StatusLight.Tone] = [.error, .attention, .idle, .live]
        let worst = lights.min { severity.firstIndex(of: $0.tone)! < severity.firstIndex(of: $1.tone)! }!
        let count = lights.filter { $0.word == worst.word }.count
        return StatusLinePart(label: "Controllers", word: "\(count) \(Self.midSentence(worst.word))", tone: worst.tone)
    }

    /// A word after a count, as in "2 connected": its first letter lowercased, unless it starts an acronym ("1 MIDI error").
    static func midSentence(_ word: String) -> String {
        let first = word.prefix { $0 != " " }
        return first.count > 1 && first == first.uppercased() ? word : word.prefix(1).lowercased() + word.dropFirst()
    }

    /// The label is always CONTROLLER, so the lights don't shift sideways; the name is in the header (#66).
    static func light(for controller: BridgeState.Controller) -> StatusLight {
        switch controller {
        case .connected: StatusLight(label: "Controller", word: "Connected", tone: .live, kind: .controller)
        case .unplugged: StatusLight(label: "Controller", word: "Unplugged", tone: .attention, kind: .controller)
        case .notConnected: StatusLight(label: "Controller", word: "Not connected", tone: .idle, kind: .controller)
        case .failed: StatusLight(label: "Controller", word: "MIDI error", tone: .attention, kind: .controller)
        case .waiting: StatusLight(label: "Controller", word: "Waiting", tone: .idle, kind: .controller)
        }
    }

    static func header(for controller: BridgeState.Controller, lastEvent: String?) -> StatusHeader {
        switch controller {
        case .connected(let profile): StatusHeader(title: profile, subtitle: lastEvent)
        case .unplugged(let profile): StatusHeader(title: profile ?? "Controller unplugged", subtitle: lastEvent)
        case .notConnected: StatusHeader(title: "No controller", subtitle: lastEvent)
        case .failed(let profile), .waiting(let profile): StatusHeader(title: profile ?? "No controller", subtitle: lastEvent)
        }
    }

    /// Lower keeps longer: DEMO and error lights, then the controller, feedback, MASTER, and DECK last.
    private static func priority(of light: StatusLight, controller: StatusLight) -> Int {
        if light.tone == .error || light.kind == .demo { return 0 }
        return light == controller ? 1 : 2
    }

    /// Drops whole parts, lowest priority first, until the line fits. The most important part always stays whole,
    /// even over the budget: a word is never cut.
    private static func fit(_ parts: [(StatusLinePart, Int)], budget: Int) -> [StatusLinePart] {
        var kept = parts
        func length(_ parts: [(StatusLinePart, Int)]) -> Int {
            parts.map(\.0.text.count).reduce(0, +) + max(0, parts.count - 1) * separator.count
        }
        while kept.count > 1, length(kept) > budget {
            // The last of the lowest-priority parts goes first.
            let worst = kept.indices.max { kept[$0].1 < kept[$1].1 || (kept[$0].1 == kept[$1].1 && $0 < $1) }!
            kept.remove(at: worst)
        }
        return kept.map(\.0)
    }
}

extension StatusLight.Tone {
    /// The tone in a theme (#127): each passes AA on that theme's surfaces.
    public func color(in palette: ThemePalette) -> RGB {
        switch self {
        case .live: palette.live
        case .idle: palette.caption
        case .attention: palette.attention
        case .error: palette.error
        }
    }
}
