import Foundation
@testable import ControllerBridgeCore
import Testing

/// The display feed's setting (#616): on/off, host and port. Off by default, so nothing goes on the network until the
/// DJ asks (#490 story 22).
@Suite("Display feed: the setting")
struct DisplayFeedSettingsTests {
    typealias Store = SettingsTests.MemoryStore

    @Test("Off by default, with no host and port 9100")
    func offByDefault() {
        #expect(SettingsTests.defaults.displayFeed == DisplayFeedSettings(enabled: false, host: "", port: 9100))
    }

    @Test("Saved settings load it back; settings saved before it load with it off")
    func roundTripAndOldSettings() throws {
        let store = Store()
        var changed = SettingsTests.defaults
        changed.displayFeed = DisplayFeedSettings(enabled: true, host: "192.168.1.40", port: 9200)
        try changed.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: SettingsTests.defaults).displayFeed == changed.displayFeed)

        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":1}],"syndicateHost":"127.0.0.1","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true}
            """#.utf8)
        #expect(BridgeSettings.load(from: store, defaults: SettingsTests.defaults).displayFeed == DisplayFeedSettings())
    }

    @Test("The USB cable has its own switch, off by default; a display feed saved before it loads with it off (#667)")
    func cableSwitch() throws {
        #expect(SettingsTests.defaults.displayFeed.cable == false)
        let store = Store()
        var changed = SettingsTests.defaults
        changed.displayFeed.cable = true
        try changed.save(to: store)
        #expect(BridgeSettings.load(from: store, defaults: SettingsTests.defaults).displayFeed.cable == true)

        store.values[BridgeSettings.storageKey] = Data(#"""
            {"controllers":[{"deck":1}],"syndicateHost":"127.0.0.1","syndicatePort":9090,"feedbackPort":9096,
             "feedbackListen":"thisMac","ledsEnabled":true,
             "displayFeed":{"enabled":true,"host":"192.168.1.40","port":9200}}
            """#.utf8)
        let old = BridgeSettings.load(from: store, defaults: SettingsTests.defaults).displayFeed
        #expect(old == DisplayFeedSettings(enabled: true, host: "192.168.1.40", port: 9200, cable: false))
    }

    @Test("The cable on with Wi-Fi off and no host is no problem (#667)")
    func cableNeedsNoHost() {
        var settings = SettingsTests.defaults
        settings.displayFeed = DisplayFeedSettings(enabled: false, host: "", port: 9100, cable: true)
        #expect(settings.problems.isEmpty)
    }

    @Test("While on, a bad host or port is a problem under its field; while off, it isn't")
    func problemsOnlyWhileOn() {
        var settings = SettingsTests.defaults
        settings.displayFeed = DisplayFeedSettings(enabled: false, host: "not a host", port: 0)
        #expect(settings.fieldProblems.isEmpty)

        settings.displayFeed.enabled = true
        #expect(settings.fieldProblems.map(\.field) == [.displayFeedHost, .displayFeedPort])
        #expect(settings.problems == [
            "not a host isn't a host name or IP address. Use the display's name, like deck-panel.local, or its IP address, like 192.168.1.40.",
            "Display feed port 0 is out of range, expected 1-65535",
        ])

        settings.displayFeed.host = " "
        settings.displayFeed.port = 9100
        #expect(settings.problems == ["The display feed's host can't be empty while it's on"])

        settings.displayFeed.host = "deck-panel.local"
        #expect(settings.problems.isEmpty)
    }

    @Test("Edited in Settings, it survives a panel deck change while Settings is open")
    func survivesRebase() {
        var draft = SettingsTests.defaults
        draft.displayFeed = DisplayFeedSettings(enabled: true, host: "192.168.1.40", port: 9100)
        var saved = SettingsTests.defaults
        saved.controllers[0].deck = 2
        let out = BridgeSettings.rebased(draft: draft, base: SettingsTests.defaults, onto: saved)
        #expect(out.displayFeed == draft.displayFeed)
        #expect(out.controllers[0].deck == 2)
    }
}
