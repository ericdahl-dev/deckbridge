@testable import ControllerBridgeCore
import Testing

/// Feedback health (#385): liveness, Resend timing, the answer and the subscription verdict, on a plain clock. Quiet
/// period 2 s, answer window 0.5 s.
@Suite("Feedback health: liveness")
struct FeedbackHealthLivenessTests {
    static func health() -> FeedbackHealth { FeedbackHealth(quiet: 2, answerWindow: 0.5) }
    /// Feedback that says nothing about subscriptions (it's always sent, #150), so only liveness changes.
    static let beat = OSCMessage("/Syndicate/ColorPalette", [.int(1), .int(0), .int(0), .int(0)])

    @Test("Waiting until the first message, then live")
    func firstMessage() {
        var health = Self.health()
        #expect(health.feedback == .waiting)
        #expect(health.messageArrived(Self.beat, at: 0) == FeedbackHealth.Output())
        #expect(health.feedback == .live)
    }

    @Test("Quiet for the quiet period: one Resend, and never a second while it waits")
    func quietAsks() {
        var health = Self.health()
        _ = health.messageArrived(Self.beat, at: 0)
        #expect(health.tick(at: 1.9, required: []).resend == false)
        #expect(health.tick(at: 2.0, required: []).resend == true)
        #expect(health.tick(at: 2.1, required: []).resend == false)
        #expect(health.requestResend(at: 2.2) == false)
    }

    @Test("No answer within the window: stale, once; then asked again every quiet period")
    func noAnswerStops() {
        var health = Self.health()
        _ = health.messageArrived(Self.beat, at: 0)
        _ = health.tick(at: 2.0, required: [])
        #expect(health.tick(at: 2.4, required: []).event == nil)
        let stopped = health.tick(at: 2.5, required: [])
        #expect(stopped.event == .stopped)
        #expect(health.feedback == .stale)
        #expect(health.tick(at: 3.0, required: []).event == nil)
        #expect(health.tick(at: 3.9, required: []).resend == false)
        #expect(health.tick(at: 4.0, required: []).resend == true)
    }

    @Test("Back after stale: live and .back, with a Resend unless it's the answer to one in its window")
    func comesBack() {
        var health = Self.health()
        _ = health.messageArrived(Self.beat, at: 0)
        _ = health.tick(at: 2.0, required: [])
        _ = health.tick(at: 2.5, required: [])
        #expect(health.messageArrived(Self.beat, at: 3.0) == FeedbackHealth.Output(resend: true, event: .back))
        #expect(health.feedback == .live)

        var answered = Self.health()
        _ = answered.messageArrived(Self.beat, at: 0)
        _ = answered.tick(at: 2.0, required: [])
        _ = answered.tick(at: 2.5, required: [])
        _ = answered.tick(at: 4.5, required: [])               // asked again at 4.5
        #expect(answered.messageArrived(Self.beat, at: 4.6) == FeedbackHealth.Output(event: .back))
    }

    @Test("resync drops a waiting Resend and asks again")
    func resync() {
        var health = Self.health()
        #expect(health.requestResend(at: 0) == true)
        #expect(health.requestResend(at: 0.1) == false)
        #expect(health.resync(at: 0.2) == true)
    }
}

/// The answer to a Resend, and what it says about subscriptions (#150, #211).
@Suite("Feedback health: subscription verdict")
struct FeedbackHealthVerdictTests {
    static func message(_ address: String, _ value: Int32 = 1) -> OSCMessage { OSCMessage("/Syndicate/" + address, [.int(value)]) }

    @Test("The window closing gives the verdict on what arrived in it: deck data, but the Cues subscription off")
    func verdictMissing() {
        var health = FeedbackHealthLivenessTests.health()
        _ = health.requestResend(at: 0)
        _ = health.messageArrived(Self.message("Deck/1/Loaded"), at: 0.1)
        _ = health.messageArrived(Self.message("Deck/1/Playing", 0), at: 0.1)
        #expect(health.tick(at: 0.4, required: [.cues]).verdict == nil)
        #expect(health.tick(at: 0.5, required: [.cues]).verdict == FeedbackHealth.Verdict(noDeckData: false, missing: [.cues]))
        #expect(health.tick(at: 0.6, required: [.cues]).verdict == nil, "once per answer")
    }

    @Test("An answer with no deck or header values: no deck data")
    func noDeckData() {
        var health = FeedbackHealthLivenessTests.health()
        _ = health.requestResend(at: 0)
        _ = health.messageArrived(OSCMessage("/Syndicate/ColorPalette", [.int(1), .int(0), .int(0), .int(0)]), at: 0.1)
        #expect(health.tick(at: 0.5, required: []).verdict?.noDeckData == true)
    }

    @Test("No answer at all says nothing about subscriptions")
    func silence() {
        var health = FeedbackHealthLivenessTests.health()
        _ = health.requestResend(at: 0)
        #expect(health.tick(at: 0.5, required: [.cues]).verdict == nil)
    }

    @Test("A message proving the subscriptions reports it at once, answer or not")
    func proves() {
        var health = FeedbackHealthLivenessTests.health()
        let loaded = health.messageArrived(Self.message("Deck/1/Loaded"), at: 0)
        let palette = health.messageArrived(OSCMessage("/Syndicate/ColorPalette", [.int(1)]), at: 0.1)
        #expect(loaded.deckDataProven)
        #expect(!palette.deckDataProven)
    }
}
