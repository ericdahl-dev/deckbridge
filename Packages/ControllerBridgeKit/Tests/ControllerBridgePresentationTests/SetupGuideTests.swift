import ControllerBridgeCore
import ControllerBridgePresentation
import Foundation
import Testing

/// The first-run guide's steps, in Syndicate's own setting names (#27). Generic: the controller is named by its profile.
@Suite("Setup guide")
struct SetupGuideTests {
    /// Core's one list (#211), as the app passes it: the LC6000's, with the jog display off (BarRamp joins only while
    /// it's on, #165): the eight, and Volume for Shift + Needle Drop's fader (#609).
    static let subscriptions = (Subscription.always + [.mixerVolume]).map(\.syndicateName)

    @Test("Four steps in Syndicate's words: OSC input, feedback destination, subscriptions, and the controller's MIDI input off")
    func steps() {
        let guide = SetupGuide(controller: "Denon LC6000 PRIME", oscPort: 9090, feedbackPort: 9096, subscriptions: Self.subscriptions)
        #expect(guide.steps.map(\.title) == [
            "Settings → OSC",
            "Settings → OSC FEEDBACK",
            "Settings → OSC FEEDBACK → SUBSCRIPTIONS",
            "Settings → MIDI",
        ])
        #expect(guide.steps.map(\.detail) == [
            "Turn OSC INPUT ENABLED on. The listen port is 9090.",
            "Set DEST IP to 127.0.0.1 and PORT to 9096.",
            "Turn on these OSC FEEDBACK subscriptions:",
            "Turn Denon LC6000 PRIME's MIDI input off. Otherwise Syndicate's own mapping and the bridge would both react to every button.",
        ])
    }

    @Test("With no profile yet, the MIDI step says \"your controller\" and names no device")
    func genericController() {
        let guide = SetupGuide(controller: nil, oscPort: 9090, feedbackPort: 9096, subscriptions: Self.subscriptions)
        #expect(guide.steps.last?.detail.hasPrefix("Turn your controller's MIDI input off.") == true)
    }

    @Test("The README's \"Set up Syndicate\" section lists the same subscriptions and says the same about the MIDI input")
    func matchesTheReadme() throws {
        // Tests/ControllerBridgePresentationTests/ → repo root.
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        let subscriptions = Self.subscriptions.dropLast().joined(separator: ", ") + " and " + Self.subscriptions.last!
        #expect(text.contains("Turn on these subscriptions: \(subscriptions)."))
        #expect(text.contains("turn your controller's MIDI input **off**"))
    }

    @Test("The guide opens on first launch and again when its content changes, but not on every launch")
    func firstRun() {
        #expect(SetupGuide.shouldShowAtLaunch(seenVersion: nil))
        #expect(!SetupGuide.shouldShowAtLaunch(seenVersion: SetupGuide.version))
        #expect(SetupGuide.shouldShowAtLaunch(seenVersion: SetupGuide.version - 1))
    }

    @Test("Step 3 lists the subscriptions as a checklist, and no step says \"Tick\" (#68)")
    func subscriptionsChecklist() {
        let guide = SetupGuide(controller: nil, oscPort: 9090, feedbackPort: 9096, subscriptions: Self.subscriptions)
        #expect(guide.steps[2].checklist == [
            "Playing", "PlayPending", "Loaded and TrackInfo", "Position/Progress", "TempoSlider and TempoSliderEnabled", "Cues",
            "BPM and Sync", "Loop", "Volume",
        ])
        #expect(guide.steps.allSatisfy { $0.checklist.isEmpty || $0.title.hasSuffix("SUBSCRIPTIONS") })
        #expect(!guide.steps.contains { $0.detail.contains("Tick") })
    }

    @Test("The ports come from settings, not literals (#68)")
    func portsFromSettings() {
        let guide = SetupGuide(controller: nil, oscPort: 8000, feedbackPort: 8001, subscriptions: Self.subscriptions)
        #expect(guide.steps[0].detail == "Turn OSC INPUT ENABLED on. The listen port is 8000.")
        #expect(guide.steps[1].detail == "Set DEST IP to 127.0.0.1 and PORT to 8001.")
    }

    @Test("The footer says what happens on start; Done confirms once feedback is live (#68)")
    func footerAndDone() {
        #expect(SetupGuide.footer == "On start, the bridge asks Syndicate to RESEND STATE, so the LEDs light at once.")
        #expect(SetupGuide.doneTitle(feedbackLive: false) == "Done")
        #expect(SetupGuide.doneTitle(feedbackLive: true) == "Done: feedback live")
    }

    @Test("The guide warns that other DJ apps can switch the controller's MIDI mode, in the README's words")
    func otherAppsNote() throws {
        #expect(SetupGuide(controller: "Denon LC6000 PRIME", oscPort: 9090, feedbackPort: 9096, subscriptions: Self.subscriptions).otherAppsNote
            == "Quit djay Pro, Engine DJ or any other app using Denon LC6000 PRIME first, and power-cycle Denon LC6000 PRIME if one was open: they can switch its MIDI mode until it restarts.")
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        #expect(text.contains(SetupGuide(controller: nil, oscPort: 9090, feedbackPort: 9096, subscriptions: Self.subscriptions).otherAppsNote))
    }
}
