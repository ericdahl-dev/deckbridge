// Which of Syndicate's OSC FEEDBACK subscriptions are on, judged from its answer to a Resend (#150).

/// A Syndicate OSC FEEDBACK subscription, the one list the setup guide shows and the check judges (#211), in the
/// guide's order.
public enum Subscription: String, CaseIterable, Equatable, Sendable {
    case playing, playPending, loaded, progress, tempoSlider, cues, sync, loop
    /// The deck's phase in the bar, for the jog display's needle (#165). Asked for only while the display is on.
    case barRamp
    /// The deck's beat offset from the master, for the drawn display's phase rule (#462) and the display feed's phase
    /// (#617). Asked for only while the unit draws or the feed is on; the mixer's Meter too.
    case phaseOffset
    /// The mixer's (#207), asked for only by a profile with those controls. Their checkbox names are from Syndicate's
    /// feedback addresses; the screen's own labels are unconfirmed.
    case mixerVolume, mixerTrim, mixerEQ, mixerFilter, mixerButtons, mixerMeter

    /// Its checkboxes, each as Syndicate's OSC Feedback screen labels it (#261: the user's screenshot shows
    /// TempoSlider and TempoSliderEnabled as two boxes, and BPM and Sync). Position/Progress is unconfirmed.
    public var checkboxes: [String] {
        switch self {
        case .playing: ["Playing"]
        case .playPending: ["PlayPending"]
        case .loaded: ["Loaded", "TrackInfo"]
        case .progress: ["Position/Progress"]
        case .tempoSlider: ["TempoSlider", "TempoSliderEnabled"]
        case .cues: ["Cues"]
        case .sync: ["BPM", "Sync"]
        case .loop: ["Loop"]
        case .barRamp: ["BarRamp"]
        case .phaseOffset: ["PhaseOffset"]
        case .mixerVolume: ["Volume"]
        case .mixerTrim: ["Trim"]
        case .mixerEQ: ["Low", "Mid", "High"]
        case .mixerFilter: ["cut", "res", "width"]
        case .mixerButtons: ["Mute", "Solo", "Cue"]
        case .mixerMeter: ["Meter"]
        }
    }

    /// The mixer values that prove a mixer subscription on (#207); empty for a deck one.
    var mixerValues: [MixerValue] {
        switch self {
        case .mixerVolume: [.volume]
        case .mixerTrim: [.trim]
        case .mixerEQ: [.eqLow, .eqMid, .eqHigh]
        case .mixerFilter: [.filterCut, .filterRes, .filterWidth]
        case .mixerButtons: [.mute, .solo, .cue]
        case .mixerMeter: [.meter]
        default: []
        }
    }

    /// Its checkboxes as one name: "TempoSlider and TempoSliderEnabled".
    public var syndicateName: String { checkboxes.joined(separator: " and ") }

    /// The subscriptions a profile needs, the only ones asked for and judged (#211): the eight every profile needs, then
    /// the mixer ones its mixer controls use (#207). Player-type ones (#210) will join the same way.
    public static func required(for mapping: Mapping) -> [Subscription] {
        guard let mixer = mapping.mixer else { return always }
        let uses: [(Subscription, Bool)] = [
            (.mixerVolume, mixer.volume != nil), (.mixerTrim, mixer.trim != nil),
            (.mixerEQ, mixer.eqLow != nil || mixer.eqMid != nil || mixer.eqHigh != nil),
            (.mixerFilter, mixer.filter != nil || mixer.filterRes != nil || mixer.filterWidth != nil),
            (.mixerButtons, mixer.cueNote != nil || mixer.muteNote != nil || mixer.soloNote != nil),
            (.mixerMeter, mixer.meter != nil),
        ]
        return always + uses.filter(\.1).map(\.0)
    }

    /// The eight every profile needs, in the guide's order. BarRamp joins only while the jog display is on (#165).
    public static let always: [Subscription] = [.playing, .playPending, .loaded, .progress, .tempoSlider, .cues, .sync, .loop]

    /// What goes wrong without it, to follow "<name> is off: ".
    public var breaks: String {
        switch self {
        case .playing: "the Play LED doesn't follow the deck"
        case .playPending: "Play won't blink while a quantized start waits"
        case .loaded:
            "the ring and Cue LED don't show a loaded track, the jog can't seek by track length, and the jog display shows no track length or time left"
        case .progress: "the jog seeks from the wrong place while paused, and the jog display's time stands still"
        case .tempoSlider: "the pitch fader can jump"
        case .cues: "hot cue pads stay dark"
        case .sync: "the Sync LED doesn't follow the deck"
        case .loop: "the loop LEDs don't follow the deck"
        case .barRamp: "the jog display's needle doesn't follow the deck"
        case .phaseOffset: "the jog display's rule doesn't show the deck's phase, and the display feed sends its phase as unknown"
        case .mixerVolume: "the channel fader can jump, and Shift + Needle Drop moves no fader in relative mode"
        case .mixerTrim: "the trim knob can jump"
        case .mixerEQ: "the EQ knobs can jump"
        case .mixerFilter: "the filter knob can jump"
        case .mixerButtons: "the cue, mute and solo LEDs don't follow the mixer"
        case .mixerMeter: "the VU meters stay dark, and the display feed's level stays at 0"
        }
    }

    /// The deck values it sends, the last part of each address, lowercased. Any one of them proves it's on: a load
    /// sends TempoSlider without TempoSliderEnabled, and a real Resend sends Position, never Progress (#211 capture).
    public var values: [String] {
        switch self {
        case .playing: ["playing"]
        case .playPending: ["playpending"]
        case .loaded: ["loaded", "trackinfo"]
        case .progress: ["position", "progress"]
        case .tempoSlider: ["temposlider", "temposliderenabled"]
        case .cues: ["cues"]
        case .sync: ["sync", "bpm"]
        case .loop: ["loop"]
        case .barRamp: ["barramp"]
        case .phaseOffset: ["phaseoffset"]
        default: []
        }
    }
}

/// Syndicate answers a Resend with every subscribed value, and always ColorPalette. Values for an empty deck aren't
/// sent, so only what arrived counts: missing values are judged only on a deck that reported Loaded 1.
struct SubscriptionCheck: Equatable {
    /// The answer had no deck and no header values (BPM, Metronome, MasterVolume…): subscriptions are off.
    var noDeckData: Bool
    /// The LED subscriptions a loaded deck lacked.
    var missing: [Subscription]

    /// Nil for no answer at all: silence says nothing about subscriptions.
    init?(answer messages: [OSCMessage], required: [Subscription] = Subscription.allCases) {
        guard !messages.isEmpty else { return nil }
        noDeckData = !messages.contains { Self.provesSubscriptions($0.address) }
        // Each deck's values, by deck number: the last two parts of /Syndicate/Deck/<n>/<Value>.
        var values: [String: Set<String>] = [:]
        var loaded: Set<String> = []
        for message in messages {
            let parts = message.address.lowercased().split(separator: "/")
            guard parts.count >= 3, parts[parts.count - 3] == "deck" else { continue }
            let deck = String(parts[parts.count - 2]), value = String(parts[parts.count - 1])
            values[deck, default: []].insert(value)
            if value == "loaded", message.arguments.first?.wholeNumber == 1 { loaded.insert(deck) }
            // With Loaded off, a track's TrackInfo still shows its deck is loaded (#308): player type last, "empty"
            // for an empty deck.
            if value == "trackinfo", case .string(let kind)? = message.arguments.last, !kind.isEmpty, kind.lowercased() != "empty" {
                loaded.insert(deck)
            }
        }
        // With Loaded and TrackInfo on, every deck sends Loaded, an empty one 0 (#211 capture). Deck values without it
        // mean that subscription is off, and then no deck can be judged loaded.
        let anyLoadedValue = values.values.contains { $0.contains("loaded") || $0.contains("trackinfo") }
        if !values.isEmpty, !anyLoadedValue, required.contains(.loaded) {
            missing = [.loaded]
            return
        }
        // Mixer values come for every channel, loaded or not (#207 capture): any channel's proves one on.
        let mixer = Set(messages.compactMap { message -> MixerValue? in
            guard let at = message.address.range(of: "/Mixer/", options: .caseInsensitive) else { return nil }
            return MixerOSC.parse(message.address, root: String(message.address[..<at.lowerBound]) + "/")?.value
        })
        // TrackInfo came but no deck sent Loaded: its checkbox is off (with it on, every deck sends Loaded).
        let anyLoaded = values.values.contains { $0.contains("loaded") }
        missing = required.filter { subscription in
            if !subscription.mixerValues.isEmpty { return mixer.isDisjoint(with: subscription.mixerValues) }
            guard subscription != .loaded else { return !values.isEmpty && !anyLoaded }
            return loaded.contains { deck in !subscription.values.contains { (values[deck] ?? []).contains($0) } }
        }
    }

    /// A deck or header value: some deck subscriptions are on.
    static func provesSubscriptions(_ address: String) -> Bool {
        let path = address.lowercased()
        return path.contains("/deck/") || path.contains("/header/")
    }
}
