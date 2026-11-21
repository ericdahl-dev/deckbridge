import Foundation

/// What the DJ sets in Settings (#19): the controllers, the OSC connection to Syndicate and the LEDs. Kept in user
/// defaults by the app.
public struct BridgeSettings: Codable, Equatable, Sendable {
    /// One entry per controller. One for now; multiple controllers (#25) add entries.
    public var controllers: [ControllerSettings]
    /// Syndicate's computer, and its OSC listen port.
    public var syndicateHost: String
    public var syndicatePort: Int
    /// Where Syndicate sends its OSC feedback.
    public var feedbackPort: Int
    public var feedbackListen: FeedbackListen
    public var ledsEnabled: Bool
    /// The deck colors follow Syndicate's cue palette (slots 1, 3, 5 and 7) (#123). On by default.
    public var followSyndicateDeckColors = true
    /// The deck colors used while following is off (#123).
    public var customDeckColors = DeckColors.defaults
    /// The ring's color mapping (#151). Vivid by default.
    public var ringColors = RingColors.vivid
    /// Pads and ring in exact RGB through Denon's color message (#530), where the controller's profile lists them. On by
    /// default, also for settings saved before it; off is the way back to the 64-color table.
    public var colorMessages = true
    /// The brightness of the color-message LEDs (pads and ring, #532), in percent: 100 is the colors as they are.
    public var lightBrightness = 100
    /// Light or dark (#127). Syndicate's own LIGHT MODE can't be read over OSC, so the DJ picks it to match.
    public var appearance = Appearance.matchMacOS
    /// "Show the deck on the jog display" (#165). On for new settings since the v1.1 hardware check.
    public var jogDisplay = true
    /// The LC6000's jog display firmware (#425): Denon's (15 image slots) or custom (16, after the slot 16 patch).
    public var displayFirmware = DisplayFirmware.denon
    /// How the jog display and its preview write the key (#590): as Syndicate sends it, or as Camelot codes.
    public var keyDisplay = KeyNotation.traditional
    /// A controller profile chosen by hand for a MIDI device (#200): device name → profile id. A device not listed is
    /// Automatic, matched by its name; so is one whose chosen profile no longer exists.
    public var profileChoices: [String: String] = [:]
    /// Shift + Needle Drop's fader (#609): on or off, relative or jump; unset keeps the profile's.
    public var stripFader = StripFaderSetting()
    /// The display feed (#490, #616): the deck in front, over OSC, to a display such as the panel. Off by default.
    public var displayFeed = DisplayFeedSettings()

    enum CodingKeys: String, CodingKey {
        case controllers, syndicateHost, syndicatePort, feedbackPort, feedbackListen, ledsEnabled
        case followSyndicateDeckColors, customDeckColors, appearance, ringColors, jogDisplay, profileChoices
        case displayFirmware, colorMessages, lightBrightness, keyDisplay, stripFader, displayFeed
    }

    /// Settings saved before #123 have no deck colors: they load with the defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controllers = try c.decode([ControllerSettings].self, forKey: .controllers)
        syndicateHost = try c.decode(String.self, forKey: .syndicateHost)
        syndicatePort = try c.decode(Int.self, forKey: .syndicatePort)
        feedbackPort = try c.decode(Int.self, forKey: .feedbackPort)
        feedbackListen = try c.decode(FeedbackListen.self, forKey: .feedbackListen)
        ledsEnabled = try c.decode(Bool.self, forKey: .ledsEnabled)
        followSyndicateDeckColors = try c.decodeIfPresent(Bool.self, forKey: .followSyndicateDeckColors) ?? true
        customDeckColors = try c.decodeIfPresent(DeckColors.self, forKey: .customDeckColors) ?? .defaults
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .matchMacOS
        ringColors = try c.decodeIfPresent(RingColors.self, forKey: .ringColors) ?? .vivid
        colorMessages = try c.decodeIfPresent(Bool.self, forKey: .colorMessages) ?? true
        lightBrightness = try c.decodeIfPresent(Int.self, forKey: .lightBrightness) ?? 100
        // Settings saved before the switch existed keep it off; new settings have it on (v1.1, RELEASE step 3).
        jogDisplay = try c.decodeIfPresent(Bool.self, forKey: .jogDisplay) ?? false
        profileChoices = try c.decodeIfPresent([String: String].self, forKey: .profileChoices) ?? [:]
        displayFirmware = try c.decodeIfPresent(DisplayFirmware.self, forKey: .displayFirmware) ?? .denon
        keyDisplay = try c.decodeIfPresent(KeyNotation.self, forKey: .keyDisplay) ?? .traditional
        stripFader = try c.decodeIfPresent(StripFaderSetting.self, forKey: .stripFader) ?? StripFaderSetting()
        displayFeed = try c.decodeIfPresent(DisplayFeedSettings.self, forKey: .displayFeed) ?? DisplayFeedSettings()
    }

    public init(
        controllers: [ControllerSettings], syndicateHost: String, syndicatePort: Int, feedbackPort: Int,
        feedbackListen: FeedbackListen, ledsEnabled: Bool
    ) {
        self.controllers = controllers
        self.syndicateHost = syndicateHost
        self.syndicatePort = syndicatePort
        self.feedbackPort = feedbackPort
        self.feedbackListen = feedbackListen
        self.ledsEnabled = ledsEnabled
    }

    /// The settings before the DJ changes anything, taken from a controller profile's mapping.
    public static func defaults(from mapping: Mapping) -> BridgeSettings {
        BridgeSettings(
            controllers: [ControllerSettings(deck: mapping.deck.number, input: nil, output: nil)],
            syndicateHost: mapping.osc.host,
            syndicatePort: mapping.osc.port,
            feedbackPort: mapping.osc.feedbackPort,
            feedbackListen: .thisMac,
            ledsEnabled: true
        )
    }
}

extension BridgeSettings {
    /// A Settings draft brought up to date with settings saved since it was loaded (#90): the new settings, plus only
    /// the fields the DJ edited in the draft (where it differs from `base`, what Settings loaded). So a deck picked in
    /// the panel while Settings is open isn't reverted by Apply.
    public static func rebased(draft: BridgeSettings, base: BridgeSettings, onto saved: BridgeSettings) -> BridgeSettings {
        func pick<T: Equatable>(_ path: KeyPath<BridgeSettings, T>) -> T {
            draft[keyPath: path] != base[keyPath: path] ? draft[keyPath: path] : saved[keyPath: path]
        }
        var out = saved
        out.syndicateHost = pick(\.syndicateHost)
        out.syndicatePort = pick(\.syndicatePort)
        out.feedbackPort = pick(\.feedbackPort)
        out.feedbackListen = pick(\.feedbackListen)
        out.ledsEnabled = pick(\.ledsEnabled)
        out.followSyndicateDeckColors = pick(\.followSyndicateDeckColors)
        out.customDeckColors = pick(\.customDeckColors)
        out.appearance = pick(\.appearance)
        out.ringColors = pick(\.ringColors)
        out.colorMessages = pick(\.colorMessages)
        out.lightBrightness = pick(\.lightBrightness)
        out.jogDisplay = pick(\.jogDisplay)
        out.displayFirmware = pick(\.displayFirmware)
        out.keyDisplay = pick(\.keyDisplay)
        out.stripFader = pick(\.stripFader)
        out.profileChoices = pick(\.profileChoices)
        out.displayFeed = pick(\.displayFeed)
        // Controllers: the draft's list (an add or remove is the DJ's edit), each field rebased where both had it.
        out.controllers = draft.controllers.indices.map { index in
            let edited = draft.controllers[index]
            guard base.controllers.indices.contains(index), saved.controllers.indices.contains(index) else { return edited }
            let was = base.controllers[index], now = saved.controllers[index]
            return ControllerSettings(
                deck: edited.deck != was.deck ? edited.deck : now.deck,
                input: edited.input != was.input ? edited.input : now.input,
                output: edited.output != was.output ? edited.output : now.output,
                channel: edited.channel != was.channel ? edited.channel : now.channel
            )
        }
        return out
    }
}

extension BridgeSettings {
    /// The user-defaults key the settings are kept under, as JSON.
    public static let storageKey = "settings.v1"

    /// The saved settings, or `defaults` when nothing is saved or what is saved can't be read.
    public static func load(from storage: any SettingsStorage, defaults: BridgeSettings) -> BridgeSettings {
        guard let data = storage.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(BridgeSettings.self, from: data) else { return defaults }
        return settings
    }

    /// Saves the settings, or throws every problem and leaves the saved settings as they were.
    public func save(to storage: any SettingsStorage) throws(SettingsError) {
        let problems = problems
        guard problems.isEmpty else { throw .invalid(problems) }
        // Encoding plain values can't fail.
        guard let data = try? JSONEncoder().encode(self) else { return }
        storage.set(data, forKey: Self.storageKey)
    }

    /// Allowed, but worth a second look before playing.
    public var warnings: [String] {
        pairs.filter { $0.settings.deck == $1.settings.deck }.map { first, second in
            "Controllers \(first.number) and \(second.number) both drive Deck \(first.settings.deck)"
        }
    }

    /// Every pair of controller entries, numbered from 1 as Settings shows them.
    private var pairs: [(ControllerEntry, ControllerEntry)] {
        let entries = zip(1..., controllers).map { ControllerEntry(number: $0, settings: $1) }
        return entries.indices.flatMap { i in entries.indices.filter { $0 > i }.map { (entries[i], entries[$0]) } }
    }

    private struct ControllerEntry {
        var number: Int
        var settings: ControllerSettings
    }

    /// What's wrong, in Syndicate's words, so the DJ can fix it.
    /// What's wrong, in Syndicate's words, so the DJ can fix it.
    public var problems: [String] { fieldProblems.map(\.message) }

    /// The same problems, each with the field it belongs to, so Settings can show it there (#68).
    public var fieldProblems: [SettingsProblem] {
        var out: [SettingsProblem] = []
        // Black is the one color the ring can't show; any other is lifted to at least its lowest level (#123).
        for deck in 1...4 where customDeckColors[deck] == [0, 0, 0] {
            out.append(SettingsProblem(
                field: .deckColor(deck: deck), message: "Deck \(deck)'s color is black, which the LC6000's ring can't show. Pick a lighter one."
            ))
        }
        for (index, controller) in controllers.enumerated() where !(1...4).contains(controller.deck) {
            out.append(SettingsProblem(field: .deck(controller: index), message: "Deck \(controller.deck) is out of range, expected 1-4"))
        }
        for (index, controller) in controllers.enumerated() {
            if let channel = controller.channel, !(1...16).contains(channel) {
                out.append(SettingsProblem(
                    field: .channel(controller: index), message: "Controller \(index + 1): channel \(channel) is out of range, expected 1-16"
                ))
            }
        }
        for (first, second) in pairs where first.settings.input != nil && first.settings.input?.id == second.settings.input?.id
            && first.settings.channel == second.settings.channel {
            let channel = first.settings.channel.map { "channel \($0)" } ?? "the same channel"
            out.append(SettingsProblem(
                field: .device(controller: second.number - 1),
                message: "Controllers \(first.number) and \(second.number) both use \(first.settings.input!.name) on \(channel)"
            ))
        }
        let host = syndicateHost.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            out.append(SettingsProblem(field: .host, message: "The Syndicate host can't be empty"))
        } else if !Self.isIPv4(host) && !Self.isHostName(host) {
            out.append(SettingsProblem(
                field: .host,
                message: "\(host) isn't a host name or IP address. Use the Mac's name, like studio-mac.local, or its IP address, like 192.168.1.20."
            ))
        }
        let ports = 1...65_535
        if !ports.contains(syndicatePort) {
            out.append(SettingsProblem(field: .oscPort, message: "OSC port \(syndicatePort) is out of range, expected 1-65535"))
        }
        if !ports.contains(feedbackPort) {
            out.append(SettingsProblem(field: .feedbackPort, message: "Feedback port \(feedbackPort) is out of range, expected 1-65535"))
        }
        if syndicatePort == feedbackPort {
            out.append(SettingsProblem(field: .feedbackPort, message: "The OSC port and the Feedback port can't both be \(syndicatePort)"))
        }
        out += displayFeed.problems
        return out
    }

    /// Four dot-separated whole numbers, 0-255 each.
    /// A host name (#84): dot-separated labels of letters, digits and hyphens, none starting or ending with a hyphen,
    /// and not all digits (that would be a malformed IPv4 address, such as 192.168.1).
    static func isHostName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.count <= 127, host.count <= 253 else { return false }
        let valid = labels.allSatisfy { label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        return valid && !labels.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    public static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }
    }
}

/// Settings that can't be saved, with a plain message for each problem.
public enum SettingsError: Error, Equatable {
    case invalid([String])
    /// Problems that belong under a field, found while putting settings into effect (#84: a host that can't be found).
    case fields([SettingsProblem])
}

/// Where settings are kept: user defaults in the app.
public protocol SettingsStorage {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
}

/// One controller: the Syndicate deck it drives and the MIDI devices it uses.
public struct ControllerSettings: Codable, Equatable, Sendable {
    /// 1-4.
    public var deck: Int
    /// The chosen MIDI input and output. Nil is automatic: the first device a controller profile matches.
    public var input: MIDIEndpoint?
    public var output: MIDIEndpoint?
    /// The MIDI channel, 1-16, to tell two controllers on one device apart (#25). Nil is the profile's channel.
    public var channel: Int?
    /// Follow the controller's own deck layers (#79): one entry per layer, channel N driving its deck. Nil is the
    /// default: follow when the profile has layers.
    public var followLayers: Bool?

    public init(deck: Int, input: MIDIEndpoint?, output: MIDIEndpoint?, channel: Int? = nil, followLayers: Bool? = nil) {
        self.deck = deck
        self.input = input
        self.output = output
        self.channel = channel
        self.followLayers = followLayers
    }

    /// The entries the Coordinator runs: a following entry becomes one per layer, on the same devices (#79).
    public static func expanded(_ entries: [ControllerSettings], layers: [Mapping.Layer]) -> [ControllerSettings] {
        entries.flatMap { entry -> [ControllerSettings] in
            guard entry.followLayers ?? true, !layers.isEmpty else { return [entry] }
            return layers.map {
                ControllerSettings(deck: $0.deck, input: entry.input, output: entry.output, channel: $0.channel, followLayers: true)
            }
        }
    }
}

/// Which network interfaces listen for Syndicate's feedback.
public enum FeedbackListen: String, Codable, Equatable, Sendable {
    /// Loopback only: Syndicate runs on this Mac. The default, with no local-network prompt.
    case thisMac
    /// Every interface, for Syndicate on another Mac. macOS asks for local-network permission.
    case allNetworks

    /// The IPv4 address the feedback listener binds to.
    public var address: String {
        switch self {
        case .thisMac: "127.0.0.1"
        case .allNetworks: "0.0.0.0"
        }
    }
}

/// A settings problem and the field it belongs to.
public struct SettingsProblem: Equatable, Sendable {
    public var field: SettingsField
    public var message: String

    public init(field: SettingsField, message: String) {
        self.field = field
        self.message = message
    }
}

/// Where in Settings a problem shows. Controllers are counted from 0.
public enum SettingsField: Hashable, Sendable {
    case deck(controller: Int)
    case channel(controller: Int)
    case device(controller: Int)
    case host
    case oscPort
    case feedbackPort
    case deckColor(deck: Int)
    case displayFeedHost
    case displayFeedPort
}

/// The display feed's setting (#616): on/off, and the display's host and port. A bad host or port is a problem only
/// while it's on. The USB cable (#667) has its own switch, apart from Wi-Fi's.
public struct DisplayFeedSettings: Codable, Equatable, Sendable {
    /// Over Wi-Fi, to `host` and `port`.
    public var enabled: Bool
    /// The display's IPv4 address or name.
    public var host: String
    public var port: Int
    /// Over the USB cable, to the deck panel plugged into this Mac (#667). Off by default.
    public var cable: Bool

    /// The panel listens on 9100 unless told otherwise.
    public static let defaultPort = 9100

    public init(enabled: Bool = false, host: String = "", port: Int = DisplayFeedSettings.defaultPort, cable: Bool = false) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.cable = cable
    }

    private enum CodingKeys: String, CodingKey { case enabled, host, port, cable }

    /// A feed saved before the cable's switch (#667) loads with it off.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        cable = try c.decodeIfPresent(Bool.self, forKey: .cable) ?? false
    }

    var problems: [SettingsProblem] {
        guard enabled else { return [] }
        var out: [SettingsProblem] = []
        let host = host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            out.append(SettingsProblem(field: .displayFeedHost, message: "The display feed's host can't be empty while it's on"))
        } else if !BridgeSettings.isIPv4(host) && !BridgeSettings.isHostName(host) {
            out.append(SettingsProblem(
                field: .displayFeedHost,
                message: "\(host) isn't a host name or IP address. Use the display's name, like deck-panel.local, or its IP address, like 192.168.1.40."
            ))
        }
        if !(1...65_535).contains(port) {
            out.append(SettingsProblem(field: .displayFeedPort, message: "Display feed port \(port) is out of range, expected 1-65535"))
        }
        return out
    }
}

/// The app's light or dark look (#127).
public enum Appearance: String, Codable, CaseIterable, Sendable {
    case matchMacOS, dark, light
}
