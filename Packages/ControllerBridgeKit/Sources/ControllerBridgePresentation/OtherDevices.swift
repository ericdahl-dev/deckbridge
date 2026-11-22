/// The MIDI sources no controller profile matches (#43), as the panel lists them.
public struct OtherDevices: Equatable, Sendable {
    /// An orange NO PROFILE row, shown on its own: only with no controller connected.
    public var highlighted: StatusLight?
    /// For each unmatched device that isn't a virtual port, the way to help add it (#200), with or without a controller
    /// connected (#329). In the order the devices came.
    public var offers: [CaptureOffer]
    /// The quiet gray line the rest collapse under, such as "Other MIDI devices (2)", natural case: the view uppercases it. Nil when there are none.
    public var summary: String?
    /// The expanded rows, in gray.
    public var rows: [String]

    /// `ownPorts` are a known controller's other ports, such as the LC6000's WD port: listed, never offered.
    public init(unmatched: [String], ownPorts: [(name: String, of: String)] = [], controllerConnected: Bool) {
        var rest = unmatched
        // An unmatched device gets the offer whether or not a controller is connected (#329). macOS's own virtual
        // ports never do.
        offers = unmatched.filter { !Self.isVirtual($0) }
            .map { CaptureOffer(device: $0, text: "\($0) isn't supported yet.", action: "Help add it…") }
        // With no controller connected, the first is probably the user's controller: call it out in orange too.
        if !controllerConnected, let index = rest.firstIndex(where: { !Self.isVirtual($0) }) {
            highlighted = StatusLight(unmatchedDevice: rest.remove(at: index))
        }
        rows = rest.map { "\($0) · no profile" } + ownPorts.map { "\($0.name) · part of the \($0.of)" }
        summary = rows.isEmpty ? nil : "Other MIDI devices (\(rows.count))"
    }

    /// The IAC Driver's buses and network MIDI sessions: ports macOS makes, not controllers.
    static func isVirtual(_ name: String) -> Bool {
        name.hasPrefix("IAC ") || name.hasPrefix("Network Session")
    }
}

/// The panel's offer for a device DeckBridge doesn't support yet (#200, #329): it opens the capture window.
public struct CaptureOffer: Equatable, Sendable {
    /// The device to capture, preselected in the window.
    public var device: String
    public var text: String
    /// The button's title.
    public var action: String

    public init(device: String, text: String, action: String) {
        self.device = device
        self.text = text
        self.action = action
    }
}
