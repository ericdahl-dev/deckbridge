import ControllerBridgePresentation
import Testing

/// Why the LEDs are dark, in plain words, with a link to the setup guide (#27). One message at a time, most urgent first.
@Suite("Help message")
struct HelpMessageTests {
    static func state(_ feedback: BridgeState.Feedback,
                      _ controller: BridgeState.Controller = .connected(profile: "Denon LC6000 PRIME")) -> BridgeState {
        BridgeState(controller: controller, feedback: feedback, deck: 1)
    }

    @Test("Port in use: says another app has the port, so feedback can't arrive, and links the guide")
    func portInUse() {
        #expect(HelpMessage(Self.state(.portInUse(port: 9096))) == HelpMessage(
            text: "Another app holds port 9096. Quit it, then reopen the bridge.",
            showsGuide: true
        ))
    }

    @Test("No feedback yet: names Syndicate's OSC FEEDBACK settings to check, and links the guide")
    func waiting() {
        #expect(HelpMessage(Self.state(.waiting(port: 9096))) == HelpMessage(
            text: "No feedback from Syndicate yet. Set OSC FEEDBACK to 127.0.0.1 : 9096.",
            showsGuide: true
        ))
    }

    @Test("Feedback dropped: asks whether Syndicate is still running, and links the guide")
    func dropped() {
        #expect(HelpMessage(Self.state(.stopped(port: 9096))) == HelpMessage(
            text: "Syndicate stopped answering. Is it still running? The LEDs catch up when it's back.",
            showsGuide: true
        ))
    }

    @Test("No controller, feedback live: says to plug it in; the guide isn't the fix, so no link")
    func noController() {
        #expect(HelpMessage(Self.state(.live(port: 9096), .notConnected)) == HelpMessage(
            text: "No controller connected. Plug it in over USB; the bridge finds it.",
            showsGuide: false
        ))
    }

    @Test("All well: no message")
    func allWell() {
        #expect(HelpMessage(Self.state(.live(port: 9096))) == nil)
    }

    @Test("Feedback problems come before a missing controller: the port message wins")
    func feedbackFirst() {
        #expect(HelpMessage(Self.state(.portInUse(port: 9096), .notConnected))?.text.hasPrefix("Another app holds port 9096") == true)
    }

    @Test("A stopped bridge says what to do in plain words, before anything else; the raw error isn't in it (#66)")
    func stopped() {
        let state = BridgeState(controller: .notConnected, feedback: .starting, deck: 1, stopped: true)
        #expect(HelpMessage(state) == HelpMessage(
            text: "The bridge couldn't open MIDI. Quit and reopen it. If that doesn't help, restart the Mac.",
            showsGuide: false
        ))
    }

    @Test("Unplugged mid-set: says to plug it back in; the bridge picks it up again by itself (#66)")
    func unplugged() {
        #expect(HelpMessage(Self.state(.live(port: 9096), .unplugged(profile: "Denon LC6000 PRIME"))) == HelpMessage(
            text: "The controller was unplugged. Plug it back in; the bridge picks it up again.",
            showsGuide: false
        ))
    }

    @Test("Stopped: the help gives the fix for the part that failed (#88)", arguments: [
        (BridgeState.StopReason.midi, "The bridge couldn't open MIDI. Quit and reopen it. If that doesn't help, restart the Mac."),
        (.oscSender, "The bridge couldn't reach Syndicate's address. Check the Syndicate host in Settings and click Apply; the bridge uses it right away."),
        (.profiles, "The bridge couldn't load its controller profiles. Reinstall the app."),
    ])
    func stoppedReasons(reason: BridgeState.StopReason, text: String) {
        let state = BridgeState(controller: .notConnected, feedback: .starting, deck: 1, stopped: true, stopReason: reason)
        #expect(HelpMessage(state) == HelpMessage(text: text, showsGuide: false))
    }

    @Test("With several controllers, help names one that needs a hand, even when the first is fine (#89)")
    func secondControllerHelp() {
        let state = BridgeState(
            controller: .connected(profile: "Denon LC6000 PRIME"), feedback: .live(port: 9096), deck: 1,
            others: [BridgeState.ControllerEntry(controller: .unplugged(profile: "Denon LC6000 PRIME"), deck: 2)]
        )
        #expect(HelpMessage(state) == HelpMessage(
            text: "Controller 2 was unplugged. Plug it back in; the bridge picks it up again.", showsGuide: false
        ))
    }

    // MARK: Another DJ app as host (#333)

    @Test("Another DJ app holds the LC6000 as host: says so and how to fix it, ahead of the subscriptions")
    func otherHost() {
        var state = Self.state(.live(port: 9096))
        state.otherHost = true
        state.missingSubscriptions = [MissingSubscription(name: "Cues", breaks: "hot cue pads stay dark")]
        #expect(HelpMessage(state) == HelpMessage(text: "Another DJ app is using the LC6000: quit it, then replug.", showsGuide: false))
    }

    @Test("A bridge that couldn't start still comes first")
    func stoppedBeatsOtherHost() {
        var state = Self.state(.live(port: 9096))
        state.otherHost = true
        state.stopped = true
        #expect(HelpMessage(state)?.text.hasPrefix("The bridge couldn't open MIDI") == true)
    }
}
