/// Why the LEDs are dark, in plain words, for the panel (#27). One message at a time, most urgent first; nil when
/// nothing needs explaining.
public struct HelpMessage: Equatable, Sendable {
    public var text: String
    /// Whether the panel links the setup guide next to it.
    public var showsGuide: Bool
    /// Syndicate subscriptions to turn on, one row each under `text` (#261); empty for any other message.
    public var subscriptions: [SubscriptionRow]

    public init(text: String, showsGuide: Bool, subscriptions: [SubscriptionRow] = []) {
        self.text = text
        self.showsGuide = showsGuide
        self.subscriptions = subscriptions
    }

    /// What VoiceOver says for the list as a whole, before its rows: how many, then the header.
    public var subscriptionsLabel: String? {
        guard !subscriptions.isEmpty else { return nil }
        let count = subscriptions.count == 1 ? "1 subscription off" : "\(subscriptions.count) subscriptions off"
        return "\(count). " + (text.hasSuffix(":") ? String(text.dropLast()) + "." : text)
    }

    public init?(_ state: BridgeState) {
        // A bridge that couldn't start comes first. The raw error is for Diagnostics, not the panel (#66).
        if state.stopped {
            switch state.stopReason {
            case .midi:
                self.init(text: "The bridge couldn't open MIDI. Quit and reopen it. If that doesn't help, restart the Mac.", showsGuide: false)
            // The sender is built at launch only, so a fixed host takes effect after a restart (#88).
            case .oscSender:
                self.init(
                    text: "The bridge couldn't reach Syndicate's address. Check the Syndicate host in Settings and click Apply; the bridge uses it right away.",
                    showsGuide: false
                )
            case .profiles:
                self.init(text: "The bridge couldn't load its controller profiles. Reinstall the app.", showsGuide: false)
            }
            return
        }
        // Another DJ app has the unit (#333): nothing else helps until it lets go.
        if state.otherHost {
            self.init(text: "Another DJ app is using the LC6000: quit it, then replug.", showsGuide: false)
            return
        }
        // Two short lines each (#66).
        switch state.feedback {
        case .portInUse(let port):
            self.init(text: "Another app holds port \(port). Quit it, then reopen the bridge.", showsGuide: true)
        case .waiting(let port):
            self.init(text: "No feedback from Syndicate yet. Set OSC FEEDBACK to 127.0.0.1 : \(port).", showsGuide: true)
        case .stopped:
            self.init(text: "Syndicate stopped answering. Is it still running? The LEDs catch up when it's back.", showsGuide: true)
        case .starting, .live, .noDeckData, .failed:
            // Every controller counts (#89): the first that needs a hand, named by its number when there are several.
            let all = [state.controller] + state.others.map(\.controller)
            guard let index = all.firstIndex(where: { if case .connected = $0 { false } else { true } }) else {
                guard let subscriptions = Self.subscriptions(state) else { return nil }
                self = subscriptions
                return
            }
            let name = all.count > 1 ? "Controller \(index + 1)" : nil
            switch all[index] {
            case .notConnected:
                self.init(text: name.map { "\($0) isn't connected. Plug it in over USB; the bridge finds it." }
                    ?? "No controller connected. Plug it in over USB; the bridge finds it.", showsGuide: false)
            case .unplugged:
                self.init(text: "\(name ?? "The controller") was unplugged. Plug it back in; the bridge picks it up again.", showsGuide: false)
            case .failed:
                self.init(text: "Lost contact with \(name?.lowercased() ?? "the controller"). Check the USB cable, then unplug and replug.",
                          showsGuide: false)
            case .waiting:
                self.init(text: name.map { "\($0) is waiting for the device chosen in Settings." } ?? "Waiting for the device chosen in Settings.",
                          showsGuide: false)
            case .connected:
                return nil
            }
        }
    }

    /// Syndicate's subscriptions off, or some missing on a loaded deck (#150), each named with what it breaks (#211).
    private static func subscriptions(_ state: BridgeState) -> HelpMessage? {
        let place = "Syndicate › Settings › OSC FEEDBACK"
        if case .noDeckData = state.feedback {
            return HelpMessage(text: "Syndicate isn't sending deck info. In \(place), turn on the subscriptions: \(list(state.requiredSubscriptions)).",
                               showsGuide: true)
        }
        let missing = state.missingSubscriptions
        guard !missing.isEmpty else { return nil }
        // A list, one row each (#261): Syndicate's own label, then what goes wrong without it.
        let these = missing.count == 1 ? "this" : "these"
        return HelpMessage(text: "Turn \(these) on in Syndicate › OSC Feedback, then Save and Close:", showsGuide: true,
                           subscriptions: missing.map { SubscriptionRow(name: $0.name, consequence: $0.breaks) })
    }

    /// "A, B and C".
    private static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

/// One Syndicate subscription that's off (#261): its label on Syndicate's OSC Feedback screen, and what goes wrong
/// without it, as a sentence.
public struct SubscriptionRow: Equatable, Sendable {
    public var name: String
    public var consequence: String

    /// `consequence` may come in lowercase, as the status words do; the row starts it with a capital.
    public init(name: String, consequence: String) {
        self.name = name
        self.consequence = consequence.prefix(1).uppercased() + consequence.dropFirst()
    }

    /// What VoiceOver says for the row.
    public var spoken: String { "\(name): " + consequence.prefix(1).lowercased() + consequence.dropFirst() }
}
