import ControllerBridgeCore
import Foundation
import Testing

/// Syndicate's Mixer subscriptions (#207, #211): asked for and judged only when the profile has those controls.
@Suite("Mixer subscriptions")
struct MixerSubscriptionsTests {
    /// The Resend answer's mixer values for channel 1, as in the real capture on #207.
    static let mixer: [OSCMessage] = [
        OSCMessage("/Syndicate/Mixer/CH1/Volume", [.float(1)]), OSCMessage("/Syndicate/Mixer/CH1/Trim", [.float(0.5)]),
        OSCMessage("/Syndicate/Mixer/CH1/EQ/Low", [.float(0.5)]), OSCMessage("/Syndicate/Mixer/CH1/EQ/Mid", [.float(0.5)]),
        OSCMessage("/Syndicate/Mixer/CH1/EQ/High", [.float(0.5)]), OSCMessage("/Syndicate/Mixer/CH1/Mute", [.int(0)]),
        OSCMessage("/Syndicate/Mixer/CH1/Solo", [.int(0)]), OSCMessage("/Syndicate/Mixer/CH1/Cue", [.int(0)]),
        OSCMessage("/Syndicate/Mixer/CH1/Meter", [.float(0)]), OSCMessage("/Syndicate/Mixer/filter1.cut", [.float(0.5)]),
    ]

    static func answered(_ messages: [OSCMessage], override: String = MixerTests.section) throws -> Rig {
        let rig = try Rig(override: override)
        rig.coordinator.start()
        rig.clock.now = 0.3
        for message in [SubscriptionsTests.palette, OSCMessage("/Syndicate/Header/BPM", [.float(120)])]
            + EverySubscriptionTests.deck1.map(\.1) + messages {
            rig.coordinator.feedback(message)
        }
        SubscriptionsTests.tick(rig, at: 2.0)
        return rig
    }

    @Test("The LC6000 asks for no mixer subscription")
    func lc6000() throws {
        #expect(Subscription.required(for: try Mapping.bundledDefault()) == Subscription.always)
    }

    @Test("A mixer profile asks for the ones its controls use, after the deck ones, by Syndicate's names")
    func required() throws {
        let mapping = try Mapping.bundledDefault(overriddenBy: Data(MixerTests.section.utf8))
        #expect(Subscription.required(for: mapping) == Subscription.always + [
            .mixerVolume, .mixerTrim, .mixerEQ, .mixerFilter, .mixerButtons, .mixerMeter,
        ])
        let volumeOnly = try Mapping.bundledDefault(overriddenBy: Data(#"{"mixer": {"volume": {"msb_cc": 19, "bits": 7}}}"#.utf8))
        #expect(Subscription.required(for: volumeOnly) == Subscription.always + [.mixerVolume])
        #expect(Subscription.mixerEQ.syndicateName == "Low and Mid and High")
        #expect(Subscription.mixerMeter.breaks == "the VU meters stay dark, and the display feed's level stays at 0")
    }

    @Test("Every mixer value in the answer: nothing missing")
    func allThere() throws {
        #expect(try Self.answered(Self.mixer).coordinator.status.missingSubscriptions == [])
    }

    @Test("No Meter and no filter in the answer: those two are missing, whatever the decks")
    func someMissing() throws {
        let rig = try Self.answered(Self.mixer.filter { !$0.address.hasSuffix("Meter") && !$0.address.contains("filter") })
        #expect(rig.coordinator.status.missingSubscriptions == [.mixerFilter, .mixerMeter])
    }
}
