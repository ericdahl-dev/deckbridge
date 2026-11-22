import ControllerBridgeCapture
import Testing

/// The capture's LED test (#187): after the steps, opt-in. Each probe lights one thing, asks, and turns it off; the
/// answers go into the file with their steps.
@Suite("LED phase")
struct LEDPhaseTests {
    static func captured() -> CaptureFlow {
        var flow = CaptureFlow(prompts: [
            CapturePrompt(id: "deck1.play", text: "Play.", gesture: .press),
            CapturePrompt(id: "deck1.hotcue1", text: "Pad 1.", gesture: .press),
        ], appVersion: "1.2.0", ledTest: true)
        flow.start(device: "Test", ports: CapturePorts(input: [], output: []), at: 0)
        flow.receive([0x90, 1, 0x7F], at: 1)
        flow.next(at: 2)
        flow.receive([0x90, 32, 0x7F], at: 3)
        flow.next(at: 4)
        return flow
    }

    /// Everything the flow lets out, a message every 100 ms, until nothing is left.
    static func drain(_ flow: inout CaptureFlow, from start: Double) -> [[UInt8]] {
        var sent: [[UInt8]] = []
        var now = start
        while flow.hasPendingSends {
            sent += flow.dueSends(at: now)
            now += 0.1
        }
        return sent
    }

    @Test("Started from the done page, each probe lights its control and asks; an answer turns it off and lights the next")
    func walk() {
        var flow = Self.captured()
        #expect(flow.phase == .done)
        flow.startLEDs(scope: .full, at: 10)
        #expect(flow.phase == .leds)
        #expect(flow.ledProbe?.text == "Did Play light up?")
        #expect(flow.takeAnnouncement() == "LED test 1 of 13. Did Play light up?")
        #expect(Self.drain(&flow, from: 10) == [[0x90, 1, 127]])

        flow.answerLED(.lit(true), at: 11)
        #expect(flow.ledProbe?.question == .level)
        #expect(Self.drain(&flow, from: 11) == [[0x90, 1, 0], [0x90, 1, 1]])
        flow.answerLED(.level(.dim), at: 12)
        _ = Self.drain(&flow, from: 12)
        flow.answerLED(.color("red"), at: 13)
        _ = Self.drain(&flow, from: 13)
        flow.answerLED(.sameAsLast, at: 14)
        _ = Self.drain(&flow, from: 14)
        flow.answerLED(.color(nil), at: 15)
        #expect(flow.ledProbe?.message == [0x90, 32, 24])

        let leds = flow.file?.steps.map(\.leds)
        #expect(leds?[0] == [LEDAnswer(sent: [0x90, 1, 127], lit: true), LEDAnswer(sent: [0x90, 1, 1], lit: true, level: .dim)])
        #expect(leds?[1] == [
            LEDAnswer(sent: [0x90, 32, 1], lit: true, color: "red"), LEDAnswer(sent: [0x90, 32, 8], lit: true, color: "red"),
            LEDAnswer(sent: [0x90, 32, 16], lit: false),
        ])
    }

    @Test("Skipping the rest turns off whatever is lit and goes back to the done page with the answers so far")
    func skipRest() {
        var flow = Self.captured()
        flow.startLEDs(scope: .full, at: 10)
        _ = Self.drain(&flow, from: 10)
        flow.skipLEDs(at: 11)
        #expect(flow.phase == .done)
        #expect(Self.drain(&flow, from: 11) == [[0x90, 1, 0]])
        #expect(flow.file?.steps.allSatisfy(\.leds.isEmpty) == true)
    }

    @Test("Answering the last probe finishes: all off, back to done, and VoiceOver hears it")
    func finish() {
        var flow = Self.captured()
        flow.startLEDs(scope: .quick, at: 10)
        var answers = 0
        while flow.phase == .leds {
            _ = Self.drain(&flow, from: 10 + Double(answers))
            flow.answerLED(flow.ledProbe?.question == .lit ? .lit(true) : .color(nil), at: 10 + Double(answers))
            answers += 1
        }
        #expect(answers == 13)
        #expect(flow.takeAnnouncement() == "LED test finished: 13 answers.")
        let sent = Self.drain(&flow, from: 30)
        #expect(sent.last?[2] == 0)
        #expect(flow.ledAnswerCount == 13)
    }

    @Test("An answer counts only once the probe has actually lit: before its message has gone out, it's ignored")
    func answerAfterShown() {
        var flow = Self.captured()
        flow.startLEDs(scope: .full, at: 10)
        #expect(!flow.canAnswerLED)
        flow.answerLED(.lit(true), at: 10)
        #expect(flow.ledProbeNumber == 1)
        _ = flow.dueSends(at: 10)
        #expect(flow.canAnswerLED)
        flow.answerLED(.lit(true), at: 10.05)
        #expect(flow.ledProbeNumber == 2)
        #expect(!flow.canAnswerLED)  // Play's off, then its low level, still to go out
    }

    @Test("Same as last needs an earlier color answer; Other is a color too")
    func sameAsLastAndOther() {
        var flow = Self.captured()
        flow.startLEDs(scope: .full, at: 10)
        for _ in 0..<2 {
            _ = Self.drain(&flow, from: 10)
            flow.answerLED(.lit(true), at: 10)
        }
        _ = Self.drain(&flow, from: 11)
        #expect(!flow.canSameAsLast)
        flow.answerLED(.sameAsLast, at: 11)
        #expect(flow.ledProbe?.message == [0x90, 32, 1])
        #expect(CaptureFlow.ledColors.last == "other")
        flow.answerLED(.color("other"), at: 11)
        _ = Self.drain(&flow, from: 12)
        #expect(flow.canSameAsLast)
    }

    @Test("The LED test runs once: afterwards it isn't offered again, so answers aren't doubled")
    func once() {
        var flow = Self.captured()
        #expect(flow.canStartLEDs)
        flow.startLEDs(scope: .quick, at: 10)
        flow.skipLEDs(at: 11)
        #expect(!flow.canStartLEDs)
        flow.startLEDs(scope: .quick, at: 12)
        #expect(flow.phase == .done)
    }

    @Test("Skip drops lights still queued instead of lighting them first, then turns off what did light")
    func skipDropsQueued() {
        var flow = Self.captured()
        flow.startLEDs(scope: .full, at: 10)
        _ = Self.drain(&flow, from: 10)
        flow.answerLED(.lit(true), at: 11)  // queues Play off, then Play at 1
        flow.skipLEDs(at: 11)
        #expect(Self.drain(&flow, from: 11) == [[0x90, 1, 0]])
    }

    @Test("Off by default until the supervised check at a unit: no offer, and starting does nothing")
    func offByDefault() {
        var flow = CaptureFlow(prompts: [CapturePrompt(id: "deck1.play", text: "Play.", gesture: .press)], appVersion: "1.2.0")
        flow.start(device: "Test", ports: CapturePorts(input: [], output: []), at: 0)
        flow.receive([0x90, 1, 0x7F], at: 1)
        flow.next(at: 2)
        #expect(flow.phase == .done)
        #expect(!flow.canStartLEDs)
        flow.startLEDs(scope: .full, at: 3)
        #expect(flow.phase == .done)
        #expect(!flow.hasPendingSends)
    }

    @Test("Unplugged mid-test (#353): the test ends with the answers so far, nothing more goes out, and it says why")
    func unpluggedMidTest() {
        var flow = Self.captured()
        flow.startLEDs(scope: .full, at: 10)
        _ = Self.drain(&flow, from: 10)
        flow.answerLED(.lit(true), at: 11)
        _ = flow.takeAnnouncement()
        flow.disconnected(at: 11.05)  // the next probe queued, not yet sent
        #expect(flow.phase == .done)
        #expect(!flow.hasPendingSends)  // its lights went off with its power
        #expect(flow.ledAnswerCount == 1)
        #expect(flow.takeAnnouncement() == "LED test ended: the controller was unplugged. 1 answers.")
        #expect(flow.takeAnnouncement() == nil)
        #expect(!flow.canStartLEDs)
    }
}
