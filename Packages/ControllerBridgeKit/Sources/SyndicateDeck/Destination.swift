import ControllerBridgeCore
import Foundation

/// Where Syndicate listens (#680): the command line's host and port, else DeckBridge's settings, else the defaults.
/// DeckBridge's preferences are only read, never written.
public struct Destination: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case commandLine, settings, defaults }

    public var host: String
    public var port: Int
    /// Where Syndicate sends its feedback: DeckBridge's port, which the tool can listen on only while it's free.
    public var feedbackPort: Int
    /// Where the host and port came from, for the line the tool prints.
    public var from: Source

    /// Syndicate's own defaults, on this Mac (as DeckBridge's bundled profile has them).
    public static let defaultHost = "127.0.0.1", defaultPort = 9090, defaultFeedbackPort = 9096

    /// DeckBridge's preferences: the sandboxed app keeps them in its container.
    public static func preferencesPath(home: String) -> String {
        home + "/Library/Containers/dev.ericdahl.ControllerBridge/Data/Library/Preferences/dev.ericdahl.ControllerBridge.plist"
    }

    /// `preferences` is the preferences file's bytes, or nil if there is none. A host or port on the command line wins
    /// over the settings, each on its own.
    public static func resolve(preferences: Data?, host: String?, port: Int?) -> Destination {
        let saved = preferences.flatMap(settings(in:))
        let from: Source = host != nil || port != nil ? .commandLine : saved != nil ? .settings : .defaults
        return Destination(host: host ?? saved?.syndicateHost ?? defaultHost,
                           port: port ?? saved?.syndicatePort ?? defaultPort,
                           feedbackPort: saved?.feedbackPort ?? defaultFeedbackPort, from: from)
    }

    static func settings(in preferences: Data) -> BridgeSettings? {
        guard let dict = try? PropertyListSerialization.propertyList(from: preferences, format: nil) as? [String: Any],
              let json = dict[BridgeSettings.storageKey] as? Data else { return nil }
        return try? JSONDecoder().decode(BridgeSettings.self, from: json)
    }
}
