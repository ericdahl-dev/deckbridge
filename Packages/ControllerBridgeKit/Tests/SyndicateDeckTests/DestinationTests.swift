@testable import ControllerBridgeCore
import Foundation
@testable import SyndicateDeck
import Testing

/// Slice 3 (#680): Syndicate's host and port, from DeckBridge's own settings (read, never written), else the defaults.
@Suite("Syndicate deck: where Syndicate is")
struct DestinationTests {
    /// A preferences file as DeckBridge leaves it: its settings as JSON under settings.v1, beside other keys.
    static func plist(host: String, port: Int, feedback: Int = 9096) throws -> Data {
        var settings = BridgeSettings.defaults(from: try Mapping.bundledDefault())
        settings.syndicateHost = host
        settings.syndicatePort = port
        settings.feedbackPort = feedback
        let dict: [String: Any] = ["settings.v1": try JSONEncoder().encode(settings), "setupGuideSeenVersion": 3]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    @Test func fromDeckBridgesSettings() throws {
        let place = Destination.resolve(preferences: try Self.plist(host: "10.0.0.5", port: 9100, feedback: 9200),
                                        host: nil, port: nil)
        #expect(place == Destination(host: "10.0.0.5", port: 9100, feedbackPort: 9200, from: .settings))
    }

    @Test func theCommandLineWins() throws {
        let place = Destination.resolve(preferences: try Self.plist(host: "10.0.0.5", port: 9100), host: "127.0.0.1",
                                        port: 9090)
        #expect(place == Destination(host: "127.0.0.1", port: 9090, feedbackPort: 9096, from: .commandLine))
    }

    /// No file, no settings in it, or settings it can't read: Syndicate's own defaults, on this Mac.
    @Test func noUsableSettingsIsTheDefault() throws {
        let noKey = try PropertyListSerialization.data(fromPropertyList: ["other": 1], format: .xml, options: 0)
        let garbled = try PropertyListSerialization.data(fromPropertyList: ["settings.v1": Data("{".utf8)],
                                                         format: .xml, options: 0)
        for preferences in [nil, Data("not a plist".utf8), noKey, garbled] {
            #expect(Destination.resolve(preferences: preferences, host: nil, port: nil)
                    == Destination(host: "127.0.0.1", port: 9090, feedbackPort: 9096, from: .defaults))
        }
    }

    /// The sandboxed app keeps its preferences in its container.
    @Test func thePreferencesFileIsTheAppsContainers() {
        #expect(Destination.preferencesPath(home: "/Users/dj")
                == "/Users/dj/Library/Containers/dev.ericdahl.ControllerBridge/Data/Library/Preferences/dev.ericdahl.ControllerBridge.plist")
    }
}
