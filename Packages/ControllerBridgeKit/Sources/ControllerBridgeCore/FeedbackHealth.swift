/// Syndicate's feedback health (#385, from #21 and #150): whether it's live, when to ask for a Resend, the answer, and
/// what the answer says about subscriptions. Syndicate sends feedback only when a value changes, so after a quiet spell
/// it's asked to resend: a live Syndicate answers with every subscribed value, and always ColorPalette (user guide
/// §14.10). Plain values in, what to do out; the Coordinator sends the Resend and acts on the events.
struct FeedbackHealth {
    /// Quiet this long, ask for a Resend; not live, ask again this often (seconds).
    var quiet: Double
    /// A Resend unanswered this long means Syndicate stopped (seconds).
    var answerWindow: Double

    private(set) var feedback: FeedbackState = .waiting
    /// When the last feedback message arrived, if any has.
    private var lastFeedbackAt: Double?
    /// When the last Resend went out, while it waits for an answer. Any feedback is the answer.
    private var resendSentAt: Double?
    /// The answer to the last Resend (#150): when it went out, and what arrived within its window.
    private var answer: (sentAt: Double, messages: [OSCMessage])?

    enum Event: Equatable, Sendable {
        /// No answer to a Resend: show idle for Syndicate's state until it's back.
        case stopped
        /// Feedback again after it stopped: the controllers repaint.
        case back
    }

    struct Output: Equatable, Sendable {
        /// Send /Syndicate/Feedback/Resend.
        var resend = false
        var event: Event?
        /// The answer window closed: what it held shows which subscriptions are on.
        var verdict: Verdict?
        /// This message proves Syndicate sends deck data, so "no deck data" is wrong now.
        var deckDataProven = false
    }

    struct Verdict: Equatable, Sendable {
        var noDeckData: Bool
        var missing: [Subscription]
    }

    init(quiet: Double, answerWindow: Double) {
        self.quiet = quiet
        self.answerWindow = answerWindow
    }

    /// Any feedback message.
    mutating func messageArrived(_ message: OSCMessage, at now: Double) -> Output {
        answer?.messages.append(message)
        let proven = SubscriptionCheck.provesSubscriptions(message.address)
        var output = arrived(at: now)
        output.deckDataProven = proven
        return output
    }

    private mutating func arrived(at now: Double) -> Output {
        let wasStale = feedback == .stale
        // An answer to a Resend still in its answer window is the full state already.
        let answering = resendSentAt.map { now - $0 < answerWindow } ?? false
        lastFeedbackAt = now
        resendSentAt = nil
        feedback = .live
        guard wasStale else { return Output() }
        return Output(resend: answering ? false : requestResend(at: now), event: .back)
    }

    /// The timers, about every 10 ms.
    mutating func tick(at now: Double, required: [Subscription]) -> Output {
        var output = Output()
        if let last = lastFeedbackAt, resendSentAt == nil, now - last >= quiet {
            output.resend = requestResend(at: now) || output.resend
        }
        if feedback == .live, let sent = resendSentAt, now - sent >= answerWindow {
            feedback = .stale
            output.event = .stopped
        }
        // Not live: ask again every quiet period, so a Syndicate that comes back quietly is found.
        if feedback != .live, let sent = resendSentAt, now - sent >= quiet {
            resendSentAt = nil
            output.resend = requestResend(at: now) || output.resend
        }
        // Once a Resend's answer window closes, what the answer held shows which subscriptions are on (#150).
        if let answer, now - answer.sentAt >= answerWindow {
            self.answer = nil
            output.verdict = SubscriptionCheck(answer: answer.messages, required: required)
                .map { Verdict(noDeckData: $0.noDeckData, missing: $0.missing) }
        }
        return output
    }

    /// Whether to send a Resend now: not while one waits for its answer.
    mutating func requestResend(at now: Double) -> Bool {
        guard resendSentAt == nil else { return false }
        resendSentAt = now
        answer = (now, [])
        return true
    }

    /// A Resend still "waiting" went out before there was anywhere to send it (#84): ask again.
    mutating func resync(at now: Double) -> Bool {
        resendSentAt = nil
        return requestResend(at: now)
    }
}
