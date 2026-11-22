/// What the menu shows: each controller's deck and whether it is connected, and the last thing that happened to it.
public struct CoordinatorStatus: Equatable, Sendable {
    public var controllers: [ControllerStatus]
    /// Every connected MIDI source and the controller profile it matched, if any.
    public var devices: [DeviceStatus]
    /// Whether Syndicate's feedback is arriving (#21).
    public var feedback: FeedbackState
    /// The last time feedback stopped, for the menu.
    public var lastDropout: String?
    /// Syndicate answered a Resend with no deck or header values: its OSC FEEDBACK subscriptions are off (#150).
    public var noDeckData = false
    /// LED subscriptions a loaded deck's answer lacked (#150), in `Subscription` order. Empty when none are missing.
    public var missingSubscriptions: [Subscription] = []
    /// The subscriptions the controllers' profiles need, in the setup guide's order (#211).
    public var requiredSubscriptions: [Subscription] = Subscription.always
    /// An LED sweep (#26) is running.
    public var sweeping = false
    /// Another DJ app holds the LC6000 as its host (#333).
    public var otherHost = false
    /// The built-in demo controller (#64) is running instead of the real one.
    public var demo = false
    /// The jog display firmware found on the unit (#456), for Settings; nil with no unit said hello to, or while asking.
    public var displayFound: DisplayFound?
    /// The deck colors in use, for the app's badges (#123): Syndicate's palette, or the defaults until it arrives.
    public var deckColors = DeckColors.defaults

    public init(
        controllers: [ControllerStatus], devices: [DeviceStatus] = [], feedback: FeedbackState = .waiting,
        lastDropout: String? = nil
    ) {
        self.controllers = controllers
        self.devices = devices
        self.feedback = feedback
        self.lastDropout = lastDropout
    }
}

extension CoordinatorStatus {
    /// The status as the menu shows it (#79): a run of layer entries (one unit following its layers) becomes the
    /// one entry for its active layer, or its first layer before any layer signal. Other controllers stay as they are.
    public func collapsingLayers() -> CoordinatorStatus {
        var out = self
        var folded: [ControllerStatus] = []
        var group: [ControllerStatus] = []
        func flush() {
            if let shown = group.first(where: \.activeLayer) ?? group.first { folded.append(shown) }
            group = []
        }
        for controller in controllers {
            if controller.followsLayers {
                // A new run starts when the channel order restarts: a second following entry's layers.
                if let last = group.last, controller.deck <= last.deck { flush() }
                group.append(controller)
            } else {
                flush()
                folded.append(controller)
            }
        }
        flush()
        out.controllers = folded
        return out
    }
}

public struct ControllerStatus: Equatable, Sendable {
    /// The Syndicate deck this controller drives, 1-4.
    public var deck: Int
    public var connected: Bool
    /// The last disconnect or reconnect, for the menu.
    public var lastEvent: String?
    /// The name of the controller profile in use, while connected.
    public var profile: String?
    /// The deck is Syndicate's tempo master: the same rule as the Master LED (#53).
    public var master: Bool
    /// The controller's LED output is open, so the LED sweep can run (#70).
    public var outputOpen: Bool
    /// The profile's name from the last connection, kept after a disconnect so the panel can still name it (#91).
    public var lastProfile: String?
    /// Why it last disconnected, if it has (#91).
    public var lastDisconnect: DisconnectReason?
    /// The MIDI device it runs on while connected (#200), so Settings can offer a profile for it.
    public var device: String?
    /// This entry is a deck layer the controller has switched to (#79): its layer note came in at velocity 127.
    public var activeLayer: Bool
    /// This entry is one deck layer of a controller that follows its own layers (#79).
    public var followsLayers: Bool

    public init(
        deck: Int, connected: Bool, lastEvent: String? = nil, profile: String? = nil, master: Bool = false, outputOpen: Bool = false,
        lastProfile: String? = nil, lastDisconnect: DisconnectReason? = nil, activeLayer: Bool = false, followsLayers: Bool = false,
        device: String? = nil
    ) {
        self.device = device
        self.lastProfile = lastProfile
        self.lastDisconnect = lastDisconnect
        self.deck = deck
        self.connected = connected
        self.lastEvent = lastEvent
        self.profile = profile
        self.master = master
        self.outputOpen = outputOpen
        self.activeLayer = activeLayer
        self.followsLayers = followsLayers
    }
}

/// A MIDI source, and the controller profile its name matched.
public struct DeviceStatus: Equatable, Sendable {
    public var name: String
    /// The matched profile's name, or nil if none matched.
    public var profile: String?
    /// A plain message for the menu, such as why the device isn't bridged.
    public var note: String?
    /// For another port of a known controller (one its profile's `exclude_hints` names, such as the LC6000's WD
    /// port), that profile's name. Such a port isn't an unsupported controller (#200).
    public var partOf: String?

    public init(name: String, profile: String?, note: String?, partOf: String? = nil) {
        self.name = name
        self.profile = profile
        self.note = note
        self.partOf = partOf
    }
}

/// Syndicate's feedback, as the bridge sees it.
public enum FeedbackState: Equatable, Sendable {
    /// None has arrived since launch.
    case waiting
    /// Arriving, or quiet but answering when asked.
    case live
    /// Stopped: it didn't answer a resend request. Syndicate's LEDs show idle until it comes back.
    case stale
}

/// Why a controller disconnected (#91): only an unplug is an unplug.
public enum DisconnectReason: Equatable, Sendable {
    /// Its MIDI source went away.
    case unplugged
    /// Sending to its LEDs failed.
    case sendFailed
    /// Reading from it failed.
    case inputFailed
    /// Settings chose other devices for it.
    case deviceChanged
    /// Its controller entry was removed in Settings.
    case removed
    /// The bridge stopped (quit).
    case stopped
}
