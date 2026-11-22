@testable import ControllerBridgeCore
import Testing

/// The one list of Syndicate OSC FEEDBACK subscriptions (#211): the setup guide shows it and the check judges it.
@Suite("Subscription list")
struct SubscriptionListTests {
    @Test("The eight, then BarRamp (#165) and PhaseOffset (#462), then the mixer's (#207), in the setup guide's order, by Syndicate's names")
    func names() {
        #expect(Subscription.allCases.map(\.syndicateName) == [
            "Playing", "PlayPending", "Loaded and TrackInfo", "Position/Progress", "TempoSlider and TempoSliderEnabled", "Cues",
            "BPM and Sync", "Loop", "BarRamp", "PhaseOffset",
            "Volume", "Trim", "Low and Mid and High", "cut and res and width", "Mute and Solo and Cue", "Meter",
        ])
        #expect(Subscription.always == [.playing, .playPending, .loaded, .progress, .tempoSlider, .cues, .sync, .loop])
    }

    @Test("Each says what breaks without it, in plain words")
    func breaks() {
        #expect(Subscription.tempoSlider.breaks == "the pitch fader can jump")
        #expect(Subscription.cues.breaks == "hot cue pads stay dark")
        #expect(Subscription.playPending.breaks == "Play won't blink while a quantized start waits")
        #expect(Subscription.allCases.allSatisfy { !$0.breaks.isEmpty })
    }

    @Test("Each is proven by any one of the deck values it sends (a load sends TempoSlider without TempoSliderEnabled)")
    func values() {
        #expect(Subscription.tempoSlider.values == ["temposlider", "temposliderenabled"])
        #expect(Subscription.loaded.values == ["loaded", "trackinfo"])
        #expect(Subscription.sync.values == ["sync", "bpm"])
        #expect(Subscription.progress.values == ["position", "progress"])
    }
}

/// Each subscription judged from a Resend's answer (#211), at the Coordinator seam. The answer is the real capture's
/// for a loaded, paused deck 1 (2026-11-16, on #211): every value it sent, with one subscription's values left out.
@Suite("Every subscription judged")
struct EverySubscriptionTests {
    static let deck1: [(Subscription, OSCMessage)] = [
        (.tempoSlider, OSCMessage("/Syndicate/Deck/1/TempoSlider", [.float(0)])),
        (.tempoSlider, OSCMessage("/Syndicate/Deck/1/TempoSliderEnabled", [.int(0)])),
        (.sync, OSCMessage("/Syndicate/Deck/1/BPM", [.float(128)])),
        (.sync, OSCMessage("/Syndicate/Deck/1/Sync", [.int(0)])),
        (.loaded, OSCMessage("/Syndicate/Deck/1/TrackInfo", [.string("t"), .string("a"), .string("8A"), .float(128), .float(200),
                                                              .int(229), .int(914), .string("track")])),
        (.cues, OSCMessage("/Syndicate/Deck/1/Cues", [.int(1), .string("Intro")] + Array(repeating: [OSCArgument.int(0), .string("")], count: 7).flatMap { $0 })),
        (.playing, OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)])),
        (.playPending, OSCMessage("/Syndicate/Deck/1/PlayPending", [.int(0)])),
        (.loaded, OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)])),
        (.progress, OSCMessage("/Syndicate/Deck/1/Position", [.float(0.25)])),
        (.loop, OSCMessage("/Syndicate/Deck/1/Loop", [.int(0)])),
    ]

    static func missing(leaving out: Subscription) throws -> [Subscription] {
        try SubscriptionsTests.answered(deck1.filter { $0.0 != out }.map(\.1)).coordinator.status.missingSubscriptions
    }

    @Test("The whole capture: nothing is missing")
    func complete() throws {
        #expect(try SubscriptionsTests.answered(Self.deck1.map(\.1)).coordinator.status.missingSubscriptions == [])
    }

    @Test("Leaving out one subscription's values flags exactly it",
          arguments: [Subscription.playing, .playPending, .progress, .tempoSlider, .cues, .sync, .loop])
    func each(subscription: Subscription) throws {
        #expect(try Self.missing(leaving: subscription) == [subscription])
    }

    @Test("TempoSlider without TempoSliderEnabled is on: a load sends just TempoSlider")
    func tempoSliderAlone() throws {
        let answer = Self.deck1.map(\.1).filter { $0.address != "/Syndicate/Deck/1/TempoSliderEnabled" }
        #expect(try SubscriptionsTests.answered(answer).coordinator.status.missingSubscriptions == [])
    }

    @Test("Empty decks send zeros and Loaded 0: they count for nothing")
    func emptyDeck() throws {
        let empty = ["Loaded", "Playing", "PlayPending"].map { OSCMessage("/Syndicate/Deck/2/\($0)", [.int(0)]) }
            + [OSCMessage("/Syndicate/Deck/2/Position", [.float(0)]), OSCMessage("/Syndicate/Deck/2/PlayerType", [.string("empty")])]
        #expect(try SubscriptionsTests.answered(Self.deck1.map(\.1) + empty).coordinator.status.missingSubscriptions == [])
    }

    @Test("Deck values with no Loaded or TrackInfo from any deck: Loaded and TrackInfo is off (nothing else can be judged)")
    func loadedMissing() throws {
        #expect(try Self.missing(leaving: .loaded) == [.loaded])
    }
}

/// Which subscriptions a profile needs (#211): only those are asked for and judged, so later mixer and player-type ones
/// (#207, #210) are asked for only by profiles that use them.
@Suite("Required subscriptions")
struct RequiredSubscriptionsTests {
    @Test("The LC6000 needs all eight")
    func lc6000() throws {
        #expect(Subscription.required(for: try Mapping.bundledDefault()) == Subscription.always)
    }

    @Test("Only the required ones are judged: a deck with only Loaded, when only Cues is required, misses only Cues")
    func onlyRequired() {
        let check = SubscriptionCheck(answer: [OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)])], required: [.cues])
        #expect(check?.missing == [.cues])
    }

    @Test("The Coordinator reports what its controllers' profiles need, for the setup guide")
    func reported() throws {
        let rig = try Rig()
        rig.coordinator.start()
        // The LC6000's Shift + Needle Drop fader reads Volume (#609).
        #expect(rig.coordinator.status.requiredSubscriptions == Subscription.always + [.mixerVolume])
    }
}

/// Syndicate's OSC Feedback screen has a checkbox per value (the user's screenshot, #261): TempoSlider and
/// TempoSliderEnabled are two boxes, as are BPM and Sync. Each subscription names its boxes.
@Suite("Subscription checkboxes")
struct SubscriptionCheckboxTests {
    @Test("TempoSlider and TempoSliderEnabled, BPM and Sync: two boxes each, named as Syndicate labels them")
    func boxes() {
        #expect(Subscription.tempoSlider.checkboxes == ["TempoSlider", "TempoSliderEnabled"])
        #expect(Subscription.sync.checkboxes == ["BPM", "Sync"])
        #expect(Subscription.cues.checkboxes == ["Cues"])
        #expect(Subscription.tempoSlider.syndicateName == "TempoSlider and TempoSliderEnabled")
    }
}
