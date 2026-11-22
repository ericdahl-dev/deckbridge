import ControllerBridgeCapture
import Testing

/// The capture window's model (#186): ports, then the steps, then done. The view only shows it.
@Suite("Capture flow")
struct CaptureFlowTests {
    static let prompts = [
        CapturePrompt(id: "idle", text: "Don't touch anything for 5 seconds.", gesture: .idle),
        CapturePrompt(id: "deck1.play", text: "Press and release Play on deck 1.", gesture: .press),
        CapturePrompt(id: "deck1.cue", text: "Press and release Cue on deck 1.", gesture: .press),
    ]
    static let ports = CapturePorts(input: ["LC6000 PRIME"], output: ["LC6000 PRIME"])

    static func started(at time: Double = 100) -> CaptureFlow {
        var flow = CaptureFlow(prompts: prompts, appVersion: "1.2.0")
        flow.start(device: "LC6000 PRIME", ports: ports, at: time)
        return flow
    }

    @Test("It starts on choosing ports, then walks the steps, numbered 1 of 3")
    func phases() {
        var flow = CaptureFlow(prompts: Self.prompts, appVersion: "1.2.0")
        #expect(flow.phase == .ports)
        #expect(flow.prompt == nil)
        flow.start(device: "LC6000 PRIME", ports: Self.ports, at: 100)
        #expect(flow.phase == .steps)
        #expect(flow.prompt?.id == "idle")
        #expect(flow.stepNumber == 1)
        #expect(flow.stepCount == 3)
    }

    @Test("The idle step: Next only after 5 seconds, with a countdown; no Skip, no Redo")
    func idleStep() {
        var flow = Self.started(at: 100)
        #expect(!flow.canNext(at: 104.9))
        #expect(flow.idleSecondsLeft(at: 100) == 5)
        #expect(flow.idleSecondsLeft(at: 102.2) == 3)
        #expect(flow.idleSecondsLeft(at: 105) == 0)
        #expect(flow.canNext(at: 105))
        #expect(!flow.canSkip)
        #expect(!flow.canRedo)
        flow.next(at: 105)
        #expect(flow.prompt?.id == "deck1.play")
        #expect(flow.idleSecondsLeft(at: 105) == nil)
    }

    @Test("A control step: Next once something is detected, Redo once anything arrived, Skip any time")
    func controlStep() {
        var flow = Self.started(at: 100)
        flow.next(at: 105)
        #expect(!flow.canNext(at: 106))
        #expect(!flow.canRedo)
        #expect(flow.canSkip)
        flow.receive([0x90, 0x01, 0x7F], at: 106)
        #expect(flow.canRedo)
        #expect(flow.canNext(at: 106))
        #expect(flow.detected.map(\.summary) == ["Note 1 on ch 1"])
        flow.redo(at: 107)
        #expect(flow.detected.isEmpty)
        #expect(!flow.canRedo)
    }

    @Test("Next or Skip on the last step finishes, and the file holds every step")
    func done() {
        var flow = Self.started(at: 100)
        flow.next(at: 105)
        flow.receive([0x90, 0x01, 0x7F], at: 106)
        flow.receive([0x80, 0x01, 0x00], at: 106.1)
        flow.next(at: 107)
        flow.skip(at: 108)
        #expect(flow.phase == .done)
        #expect(flow.prompt == nil)
        #expect(flow.file?.steps.map(\.prompt) == ["idle", "deck1.play", "deck1.cue"])
        #expect(flow.file?.steps.map(\.status) == [.confirmed, .confirmed, .skipped])
        #expect(flow.file?.device == "LC6000 PRIME")
    }

    @Test("A long burst is worked out at most every 100 ms, the first detection at once, and the rest on the next tick")
    func throttled() {
        var flow = Self.started(at: 100)
        flow.next(at: 105)
        flow.receive([0x90, 0x01, 0x7F], at: 106.00)
        #expect(flow.detected.map(\.summary) == ["Note 1 on ch 1"])
        flow.receive([0x90, 0x02, 0x7F], at: 106.05)
        #expect(flow.detected.map(\.summary) == ["Note 1 on ch 1"])
        flow.receive([0x90, 0x03, 0x7F], at: 106.12)
        #expect(flow.detected.map(\.summary) == ["Note 1 on ch 1", "Note 2 on ch 1", "Note 3 on ch 1"])
        flow.receive([0x90, 0x04, 0x7F], at: 106.13)
        flow.tick(at: 106.14)
        #expect(flow.detected.count == 4)
    }

    @Test("VoiceOver hears each new prompt and each change in what's detected, not every message")
    func announcements() {
        var flow = Self.started(at: 100)
        #expect(flow.takeAnnouncement() == "Step 1 of 3. Don't touch anything for 5 seconds.")
        #expect(flow.takeAnnouncement() == nil)
        flow.next(at: 105)
        #expect(flow.takeAnnouncement() == "Step 2 of 3. Press and release Play on deck 1.")

        flow.receive([0x90, 0x01, 0x7F], at: 106)
        #expect(flow.takeAnnouncement() == "Detected: Note 1 on channel 1.")
        flow.receive([0x80, 0x01, 0x00], at: 106.1)
        flow.receive([0x90, 0x01, 0x7F], at: 106.5)
        #expect(flow.takeAnnouncement() == nil)
        flow.receive([0x90, 0x02, 0x7F], at: 106.55)  // within 100 ms of the last refresh: shown on the next tick
        #expect(flow.takeAnnouncement() == nil)
        flow.tick(at: 106.8)
        #expect(flow.takeAnnouncement() == "Detected: Note 1 on channel 1, then Note 2 on channel 1.")

        flow.redo(at: 107)
        #expect(flow.takeAnnouncement() == nil)
        flow.receive([0x90, 0x01, 0x7F], at: 107.5)
        #expect(flow.takeAnnouncement() == "Detected: Note 1 on channel 1.")
        flow.next(at: 108)
        flow.skip(at: 109)
        #expect(flow.takeAnnouncement() == "Capture finished: 3 steps, 1 skipped.")
    }

    @Test("On the idle step, VoiceOver hears once when Next is ready")
    func idleReady() {
        var flow = Self.started(at: 100)
        _ = flow.takeAnnouncement()
        flow.tick(at: 103)
        #expect(flow.takeAnnouncement() == nil)
        flow.tick(at: 105.1)
        #expect(flow.takeAnnouncement() == "Done listening. Next is available.")
        flow.tick(at: 106)
        #expect(flow.takeAnnouncement() == nil)
    }

    @Test("The owner's note goes into the file trimmed; a blank one leaves the note out")
    func note() throws {
        var flow = Self.started(at: 100)
        flow.note = "  Firmware 1.3, left deck only \n"
        #expect(flow.file?.note == "Firmware 1.3, left deck only")
        flow.note = "   "
        #expect(flow.file?.note == nil)
        let json = String(decoding: try #require(try flow.file?.encoded()), as: UTF8.self)
        #expect(!json.contains("\"note\""))
    }

    // MARK: Unplug mid-capture (#229)

    @Test("Unplugged mid-step: the buttons are off, MIDI is ignored, and VoiceOver hears what to do")
    func disconnected() {
        var flow = Self.started(at: 100)
        flow.next(at: 105)
        _ = flow.takeAnnouncement()
        flow.receive([0x90, 0x01, 0x7F], at: 106)
        _ = flow.takeAnnouncement()
        flow.disconnected(at: 107)
        #expect(flow.isDisconnected)
        #expect(!flow.canNext(at: 107))
        #expect(!flow.canRedo)
        #expect(!flow.canSkip)
        #expect(flow.takeAnnouncement() == "Controller disconnected. Plug it back in to continue, or end the capture.")
        flow.receive([0x90, 0x02, 0x7F], at: 108)
        flow.skip(at: 108)
        #expect(flow.prompt?.id == "deck1.play")
    }

    @Test("Plugged back in: the same step starts again, its partial take thrown away")
    func reconnected() {
        var flow = Self.started(at: 100)
        flow.next(at: 105)
        flow.receive([0x90, 0x01, 0x7F], at: 106)
        flow.disconnected(at: 107)
        _ = flow.takeAnnouncement()
        flow.reconnected(at: 110)
        #expect(!flow.isDisconnected)
        #expect(flow.prompt?.id == "deck1.play")
        #expect(flow.detected.isEmpty)
        #expect(flow.takeAnnouncement() == "Controller reconnected. Step 2 of 3. Press and release Play on deck 1.")
        flow.receive([0x90, 0x01, 0x7F], at: 111)
        #expect(flow.canNext(at: 111))
    }

    @Test("Ending the capture early keeps the steps so far, leaves the rest out, and the summary says it's partial")
    func endEarly() throws {
        var flow = Self.started(at: 100)
        flow.next(at: 105)
        flow.receive([0x90, 0x01, 0x7F], at: 106)
        flow.disconnected(at: 107)
        _ = flow.takeAnnouncement()
        flow.endCapture(at: 108)
        #expect(flow.phase == .done)
        let file = try #require(flow.file)
        #expect(file.steps.map(\.prompt) == ["idle"])
        #expect(file.summary.contains("Ended early: 1 of 3 steps"))
        #expect(flow.takeAnnouncement() == "Capture ended early: 1 of 3 steps.")
    }

    @Test("Replugged on the idle step, it listens again and VoiceOver hears \"Next is available\" again (#316)")
    func idleReadyAfterReplug() {
        var flow = Self.started(at: 100)
        _ = flow.takeAnnouncement()
        flow.tick(at: 105.1)
        #expect(flow.takeAnnouncement() == "Done listening. Next is available.")
        flow.disconnected(at: 106)
        _ = flow.takeAnnouncement()
        flow.reconnected(at: 110)
        _ = flow.takeAnnouncement()
        flow.tick(at: 112)
        #expect(flow.takeAnnouncement() == nil)
        flow.tick(at: 115.1)
        #expect(flow.takeAnnouncement() == "Done listening. Next is available.")
    }
}
