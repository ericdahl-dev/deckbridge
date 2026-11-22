import Foundation
import ControllerBridgeCore
import Testing

/// The app's settings: a list of controller entries plus the shared OSC settings, kept in user defaults.
@Suite("Settings")
struct SettingsTests {
    @Test("Defaults come from the LC6000 profile: one controller on deck 1 with no device chosen, Syndicate on loopback")
    func defaults() throws {
        let settings = BridgeSettings.defaults(from: try Mapping.bundledDefault())
        #expect(settings == BridgeSettings(
            controllers: [ControllerSettings(deck: 1, input: nil, output: nil)],
            syndicateHost: "127.0.0.1",
            syndicatePort: 9090,
            feedbackPort: 9096,
            feedbackListen: .thisMac,
            ledsEnabled: true
        ))
    }

    /// User defaults stand-in.
    final class MemoryStore: SettingsStorage, @unchecked Sendable {
        var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func set(_ data: Data, forKey key: String) { values[key] = data }
    }

    static let defaults = BridgeSettings(
        controllers: [ControllerSettings(deck: 1, input: nil, output: nil)],
        syndicateHost: "127.0.0.1", syndicatePort: 9090, feedbackPort: 9096, feedbackListen: .thisMac, ledsEnabled: true
    )

    @Test("Saved settings load back as saved")
    func roundTrip() throws {
        let store = MemoryStore()
        var changed = Self.defaults
        changed.controllers[0] = ControllerSettings(
            deck: 3, input: MIDIEndpoint(id: 1001, name: "DENON LC6000 PRIME"), output: MIDIEndpoint(id: 2001, name: "DENON LC6000 PRIME")
        )
        changed.syndicateHost = "192.168.1.20"
        changed.feedbackListen = .allNetworks
        changed.ledsEnabled = false
        try changed.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults) == changed)
    }

    // #123: deck colors are the user's taste, so they're in the settings, not the profile.

    @Test("Deck colors: following Syndicate is the default, and custom colors start as the defaults")
    func deckColorDefaults() {
        #expect(Self.defaults.followSyndicateDeckColors)
        #expect(Self.defaults.customDeckColors == .defaults)
    }

    @Test("Custom deck colors and the follow switch load back as saved")
    func deckColorsRoundTrip() throws {
        let store = MemoryStore()
        var changed = Self.defaults
        changed.followSyndicateDeckColors = false
        changed.customDeckColors.rgb[2] = [0, 0, 255]
        try changed.save(to: store)
        let loaded = BridgeSettings.load(from: store, defaults: Self.defaults)
        #expect(loaded.followSyndicateDeckColors == false)
        #expect(loaded.customDeckColors[2] == [0, 0, 255])
    }

    @Test("Settings saved before #123 still load, with deck colors at their defaults")
    func settingsBeforeDeckColors() {
        let store = MemoryStore()
        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":3}],"syndicateHost":"192.168.1.20","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true}
            """#.utf8)
        let loaded = BridgeSettings.load(from: store, defaults: Self.defaults)
        #expect(loaded.syndicateHost == "192.168.1.20")
        #expect(loaded.followSyndicateDeckColors)
        #expect(loaded.customDeckColors == .defaults)
    }

    @Test("A controller chosen by hand for a device (#200) loads back; settings saved before it load with none: Automatic")
    func profileChoices() throws {
        #expect(Self.defaults.profileChoices == [:])
        let store = MemoryStore()
        var changed = Self.defaults
        changed.profileChoices = ["Mystery DJ 2": "denon-lc6000-prime"]
        try changed.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).profileChoices == ["Mystery DJ 2": "denon-lc6000-prime"])

        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":1}],"syndicateHost":"127.0.0.1","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true}
            """#.utf8)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).profileChoices == [:])
    }

    @Test("A controller choice made in Settings survives a panel deck change while Settings is open (#200)")
    func profileChoiceRebased() {
        var draft = Self.defaults
        draft.profileChoices = ["Mystery DJ 2": "denon-lc6000-prime"]
        var saved = Self.defaults
        saved.controllers[0].deck = 2
        let out = BridgeSettings.rebased(draft: draft, base: Self.defaults, onto: saved)
        #expect(out.profileChoices == ["Mystery DJ 2": "denon-lc6000-prime"])
        #expect(out.controllers[0].deck == 2)
    }

    @Test("Nothing saved, or saved data that can't be read, loads the defaults")
    func missingOrCorruptLoadsDefaults() {
        let store = MemoryStore()
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults) == Self.defaults)
        store.values[BridgeSettings.storageKey] = Data("not json".utf8)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults) == Self.defaults)
    }

    @Test("This Mac only listens on 127.0.0.1; All networks listens on 0.0.0.0")
    func listenAddress() {
        #expect(FeedbackListen.thisMac.address == "127.0.0.1")
        #expect(FeedbackListen.allNetworks.address == "0.0.0.0")
    }

    @Test("Bad settings are refused with every problem in plain words, and the saved settings stay as they were")
    func badSettingsRefused() throws {
        let store = MemoryStore()
        try Self.defaults.save(to: store)
        var bad = Self.defaults
        bad.controllers[0].deck = 5
        bad.syndicateHost = "  "
        bad.syndicatePort = 0
        bad.feedbackPort = 70_000
        #expect(throws: SettingsError.invalid([
            "Deck 5 is out of range, expected 1-4",
            "The Syndicate host can't be empty",
            "OSC port 0 is out of range, expected 1-65535",
            "Feedback port 70000 is out of range, expected 1-65535",
        ])) { try bad.save(to: store) }
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults) == Self.defaults)
    }

    @Test("The OSC port and the Feedback port can't be the same")
    func portsMustDiffer() {
        var bad = Self.defaults
        bad.feedbackPort = 9090
        #expect(throws: SettingsError.invalid(["The OSC port and the Feedback port can't both be 9090"])) {
            try bad.save(to: MemoryStore())
        }
    }

    static let lc6000 = MIDIEndpoint(id: 1001, name: "DENON LC6000 PRIME")

    @Test("Two controllers on the same device and channel are refused; a channel outside 1-16 is too")
    func sameDeviceAndChannelRefused() {
        var bad = Self.defaults
        bad.controllers = [
            ControllerSettings(deck: 1, input: Self.lc6000, output: nil, channel: 1),
            ControllerSettings(deck: 2, input: Self.lc6000, output: nil, channel: 1),
            ControllerSettings(deck: 3, input: nil, output: nil, channel: 17),
        ]
        #expect(throws: SettingsError.invalid([
            "Controller 3: channel 17 is out of range, expected 1-16",
            "Controllers 1 and 2 both use DENON LC6000 PRIME on channel 1",
        ])) { try bad.save(to: MemoryStore()) }
    }

    @Test("Two controllers on one deck is allowed, with a warning that doesn't stop the save")
    func sameDeckWarns() throws {
        let store = MemoryStore()
        var settings = Self.defaults
        settings.controllers = [
            ControllerSettings(deck: 1, input: Self.lc6000, output: nil, channel: 1),
            ControllerSettings(deck: 1, input: Self.lc6000, output: nil, channel: 2),
        ]
        #expect(settings.warnings == ["Controllers 1 and 2 both drive Deck 1"])
        try settings.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults) == settings)
    }

    @Test("Each problem names its field, so Settings can show it under that field (#68)")
    func problemsNameTheirField() {
        var bad = Self.defaults
        bad.controllers[0].deck = 5
        bad.syndicateHost = "  "
        bad.syndicatePort = 0
        bad.feedbackPort = 70_000
        #expect(bad.fieldProblems == [
            SettingsProblem(field: .deck(controller: 0), message: "Deck 5 is out of range, expected 1-4"),
            SettingsProblem(field: .host, message: "The Syndicate host can't be empty"),
            SettingsProblem(field: .oscPort, message: "OSC port 0 is out of range, expected 1-65535"),
            SettingsProblem(field: .feedbackPort, message: "Feedback port 70000 is out of range, expected 1-65535"),
        ])
        #expect(bad.problems == bad.fieldProblems.map(\.message))
    }

    @Test("A host name is fine too (#84): letters, digits and hyphens in dot-separated labels, .local included", arguments: [
        "studio-mac.local", "localhost", "syndicate", "Studio-Mac-2.local", " studio-mac.local ",
    ])
    func hostNamesAccepted(host: String) {
        var good = Self.defaults
        good.syndicateHost = host
        #expect(good.fieldProblems == [])
    }

    @Test("A malformed name, or a numeric address that isn't IPv4, gets one plain problem (#84)", arguments: [
        "studio mac", "-bad.local", "bad-.local", "a..b", "studio_mac.local", "999.1.1.1", "192.168.1", "192.168.1.20.5",
    ])
    func hostMalformed(host: String) {
        var bad = Self.defaults
        bad.syndicateHost = host
        #expect(bad.fieldProblems == [SettingsProblem(
            field: .host,
            message: "\(host) isn't a host name or IP address. Use the Mac's name, like studio-mac.local, or its IP address, like 192.168.1.20."
        )])
    }

    @Test("IPv4 addresses are fine, loopback included", arguments: ["127.0.0.1", "192.168.1.20", "10.0.0.255", " 192.168.1.20 "])
    func ipv4Accepted(host: String) {
        var good = Self.defaults
        good.syndicateHost = host
        #expect(good.fieldProblems == [])
    }

    // A stale Settings draft (#90): Settings keeps the settings it loaded as `base`. When the saved settings change
    // under it (a deck click in the panel), its draft becomes the new settings plus only the fields the DJ edited.

    @Test("A deck picked in the panel while Settings is open survives Apply of another field (#90)")
    func panelDeckSurvivesSettingsApply() {
        let base = Self.defaults
        var draft = base
        draft.syndicateHost = "192.168.1.20"            // edited in Settings
        var saved = base
        saved.controllers[0].deck = 3                  // picked in the panel
        let rebased = BridgeSettings.rebased(draft: draft, base: base, onto: saved)
        #expect(rebased.controllers[0].deck == 3)
        #expect(rebased.syndicateHost == "192.168.1.20")
    }

    @Test("Deck colors edited in Settings survive a panel deck change while Settings is open (#123)")
    func deckColorEditsSurviveRebase() {
        let base = Self.defaults
        var draft = base
        draft.followSyndicateDeckColors = false
        draft.customDeckColors.rgb[2] = [0, 0, 255]
        var saved = base
        saved.controllers[0].deck = 3
        let rebased = BridgeSettings.rebased(draft: draft, base: base, onto: saved)
        #expect(rebased.controllers[0].deck == 3)
        #expect(rebased.followSyndicateDeckColors == false)
        #expect(rebased.customDeckColors[2] == [0, 0, 255])
    }

    @Test("A black custom deck color is refused: the LC6000 ring would be off")
    func blackDeckColorRefused() {
        var settings = Self.defaults
        settings.customDeckColors.rgb[3] = [0, 0, 0]
        #expect(settings.fieldProblems == [SettingsProblem(
            field: .deckColor(deck: 3), message: "Deck 3's color is black, which the LC6000's ring can't show. Pick a lighter one."
        )])
        settings.customDeckColors.rgb[3] = [10, 0, 0]   // dim, but the ring lifts it to its lowest red
        #expect(settings.fieldProblems == [])
    }

    // #136: only a host change waits on the network; everything else applies at once, and nothing reverts anything.

    @Test("A deck, LED or color change needs no connect, even while the sender isn't ready")
    func deckChangeNeedsNoConnect() {
        var new = Self.defaults
        new.controllers[0].deck = 3
        new.ledsEnabled = false
        new.followSyndicateDeckColors = false
        #expect(BridgeSettings.connection(to: new, from: Self.defaults, senderReady: true) == nil)
        #expect(BridgeSettings.connection(to: new, from: Self.defaults, senderReady: false, retry: false) == nil)
    }

    @Test("A host or port change connects; so does Settings' Apply while the sender never opened (#109)")
    func hostChangeConnects() {
        var new = Self.defaults
        new.syndicateHost = "studio.local"
        #expect(BridgeSettings.connection(to: new, from: Self.defaults, senderReady: true)
            == BridgeSettings.Connection(host: "studio.local", port: 9090))
        new = Self.defaults
        new.syndicatePort = 9191
        #expect(BridgeSettings.connection(to: new, from: Self.defaults, senderReady: true)
            == BridgeSettings.Connection(host: "127.0.0.1", port: 9191))
        #expect(BridgeSettings.connection(to: Self.defaults, from: Self.defaults, senderReady: false)
            == BridgeSettings.Connection(host: "127.0.0.1", port: 9090))
    }

    @Test("The immediate part is everything but the host and port")
    func immediatePart() {
        var new = Self.defaults
        new.syndicateHost = "studio.local"
        new.syndicatePort = 9191
        new.controllers[0].deck = 2
        let now = BridgeSettings.immediate(new, keeping: Self.defaults)
        #expect(now.syndicateHost == "127.0.0.1")
        #expect(now.syndicatePort == 9090)
        #expect(now.controllers[0].deck == 2)
    }

    @Test("A host that opens after a deck click lands on the settings as they are then: the deck stays")
    func connectedKeepsLaterChanges() {
        var current = Self.defaults
        current.controllers[0].deck = 4                 // clicked while the host was resolving
        let after = current.connected(host: "studio.local", port: 9191)
        #expect(after.controllers[0].deck == 4)
        #expect(after.syndicateHost == "studio.local")
        #expect(after.syndicatePort == 9191)
    }

    // #151: the ring's color mapping.

    @Test("Ring colors default to Vivid; old settings load as Vivid; Exact round-trips and survives a rebase")
    func ringColorsSetting() {
        #expect(Self.defaults.ringColors == .vivid)
        let store = MemoryStore()
        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":1}],"syndicateHost":"127.0.0.1","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true}
            """#.utf8)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).ringColors == .vivid)
        var exact = Self.defaults
        exact.ringColors = .exact
        try? exact.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).ringColors == .exact)
        var saved = Self.defaults
        saved.controllers[0].deck = 2
        #expect(BridgeSettings.rebased(draft: exact, base: Self.defaults, onto: saved).ringColors == .exact)
    }

    @Test("Shift + Needle Drop's fader (#609): old settings keep the profile's choice; a choice round-trips and survives a rebase")
    func stripFaderSetting() {
        let store = MemoryStore()
        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":1}],"syndicateHost":"127.0.0.1","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true}
            """#.utf8)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).stripFader == StripFaderSetting())
        var jump = Self.defaults
        jump.stripFader = StripFaderSetting(enabled: true, mode: .jump)
        try? jump.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).stripFader == StripFaderSetting(enabled: true, mode: .jump))
        var saved = Self.defaults
        saved.controllers[0].deck = 2
        #expect(BridgeSettings.rebased(draft: jump, base: Self.defaults, onto: saved).stripFader.mode == .jump)
    }

    // #530: pads and ring in exact RGB through Denon's color message, or the 64-color table.

    @Test("The color message is on by default, also for old settings; the table (the way back) round-trips and survives a rebase")
    func colorMessagesSetting() {
        #expect(Self.defaults.colorMessages)
        let store = MemoryStore()
        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":1}],"syndicateHost":"127.0.0.1","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true}
            """#.utf8)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).colorMessages)
        var table = Self.defaults
        table.colorMessages = false
        try? table.save(to: store)
        #expect(!BridgeSettings.load(from: store, defaults: Self.defaults).colorMessages)
        var saved = Self.defaults
        saved.controllers[0].deck = 2
        #expect(!BridgeSettings.rebased(draft: table, base: Self.defaults, onto: saved).colorMessages)
    }

    // #532: a brightness for the color-message LEDs (pads and ring), in percent; full is today's level.

    @Test("Light brightness is 100% (today's level) by default, also for old settings; a dimmer one round-trips and survives a rebase")
    func lightBrightnessSetting() {
        #expect(Self.defaults.lightBrightness == 100)
        let store = MemoryStore()
        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":1}],"syndicateHost":"127.0.0.1","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true}
            """#.utf8)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).lightBrightness == 100)
        var dim = Self.defaults
        dim.lightBrightness = 40
        try? dim.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).lightBrightness == 40)
        var saved = Self.defaults
        saved.controllers[0].deck = 2
        #expect(BridgeSettings.rebased(draft: dim, base: Self.defaults, onto: saved).lightBrightness == 40)
    }

    // #425: the LC6000's display firmware, Denon's or custom.

    @Test("Display firmware defaults to Denon's; old settings load as Denon's; Custom round-trips and survives a rebase")
    func displayFirmwareSetting() {
        #expect(Self.defaults.displayFirmware == .denon)
        let store = MemoryStore()
        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":1}],"syndicateHost":"127.0.0.1","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true}
            """#.utf8)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).displayFirmware == .denon)
        var custom = Self.defaults
        custom.displayFirmware = .custom
        try? custom.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).displayFirmware == .custom)
        var saved = Self.defaults
        saved.controllers[0].deck = 2
        #expect(BridgeSettings.rebased(draft: custom, base: Self.defaults, onto: saved).displayFirmware == .custom)
    }

    // #590: how the jog display writes the key.

    @Test("Key display defaults to Traditional; old settings load as Traditional; Camelot round-trips and survives a rebase")
    func keyDisplaySetting() {
        #expect(Self.defaults.keyDisplay == .traditional)
        let store = MemoryStore()
        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":1}],"syndicateHost":"127.0.0.1","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true}
            """#.utf8)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).keyDisplay == .traditional)
        var camelot = Self.defaults
        camelot.keyDisplay = .camelot
        try? camelot.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).keyDisplay == .camelot)
        var saved = Self.defaults
        saved.controllers[0].deck = 2
        #expect(BridgeSettings.rebased(draft: camelot, base: Self.defaults, onto: saved).keyDisplay == .camelot)
    }

    @Test("A field the DJ also edited in Settings keeps the DJ's value")
    func editedFieldWins() {
        let base = Self.defaults
        var draft = base
        draft.controllers[0].deck = 2
        var saved = base
        saved.controllers[0].deck = 3
        #expect(BridgeSettings.rebased(draft: draft, base: base, onto: saved).controllers[0].deck == 2)
    }

    @Test("With nothing edited in Settings, the draft is simply the new settings")
    func nothingEdited() {
        var saved = Self.defaults
        saved.controllers[0].deck = 4
        saved.feedbackPort = 9100
        #expect(BridgeSettings.rebased(draft: Self.defaults, base: Self.defaults, onto: saved) == saved)
    }

    @Test("A controller added in Settings stays, and the panel's deck change still lands on controller 1")
    func addedControllerStays() {
        let base = Self.defaults
        var draft = base
        draft.controllers.append(ControllerSettings(deck: 2, input: nil, output: nil))
        var saved = base
        saved.controllers[0].deck = 3
        let rebased = BridgeSettings.rebased(draft: draft, base: base, onto: saved)
        #expect(rebased.controllers.map(\.deck) == [3, 2])
    }

    @Test("Appearance (#127): Match macOS by default, saved like the rest, and settings saved before it read as Match macOS")
    func appearance() throws {
        #expect(Self.defaults.appearance == .matchMacOS)
        let store = MemoryStore()
        var dark = Self.defaults
        dark.appearance = .dark
        try dark.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: Self.defaults).appearance == .dark)

        let old = Data(#"{"controllers": [{"deck": 1}], "syndicateHost": "127.0.0.1", "syndicatePort": 9090, "feedbackPort": 9096, "feedbackListen": "thisMac", "ledsEnabled": true}"#.utf8)
        #expect(try JSONDecoder().decode(BridgeSettings.self, from: old).appearance == .matchMacOS)
    }

    @Test("An appearance picked in the Settings draft survives a rebase onto newer saved settings (#127)")
    func appearanceRebases() {
        var draft = Self.defaults
        draft.appearance = .light
        var saved = Self.defaults
        saved.ledsEnabled = false
        let rebased = BridgeSettings.rebased(draft: draft, base: Self.defaults, onto: saved)
        #expect(rebased.appearance == .light)
        #expect(rebased.ledsEnabled == false)
    }
}
