/// The Bridge's cue memory (#383): the Shift + pad jump to a hot cue on a stopped deck (#358, #363), and the main cue
/// point Shift + CUE goes back to (#360). Syndicate never reports cue times, so both learn them from its Position.
/// Plain values in, sends out: the Bridge sends the OSC to its deck and applies the quantize holds.
struct CueModule {
    enum Send: Equatable, Sendable {
        /// A message to this deck: its address after /Syndicate/Deck/N/.
        case osc(String, OSCArgument)
        case hold(QuantizeOverride.Reason)
        case release(QuantizeOverride.Reason)
    }

    /// Syndicate's first Position after a launch is this far past the cue (the live check on #358: 0.06 s, every run).
    static let launchReportLead = 0.06
    /// How long a Shift + pad tap waits for its launch before the pause is dropped and quantize put back.
    static let cuePauseTimeout = 4.0
    /// How long after CUE-while-playing the deck's stop says where the cue point is.
    static let mainCueSettle = 0.5
    /// Closer than this to the cue point is on it.
    static let onCuePoint = 0.02

    /// A Shift + pad tap waiting for Syndicate's Playing 1 to pause it: the cue, and when.
    private var pending: (cue: Int, armedAt: Double)?
    /// Where each hot cue sits, in seconds, learned from a Shift + pad launch.
    private var cueTimes: [Int: Double] = [:]
    /// The cue just launched by Shift + pad, whose time the next Position gives.
    private var learningCue: Int?
    /// Where the main cue point is, and until when a stop after CUE-while-playing gives it.
    private var mainCue: Double?
    private var mainCueSettlesUntil: Double?
    /// Where the deck last was, from Position.
    private(set) var position: Double?

    var isJumpPending: Bool { pending != nil }

    /// Shift + hot cue pad on a stopped deck: go to cue `cue` without playing, at once whatever quantize is (#363).
    /// Learned, a WaveformSeek there, which is silent and, unquantized, lands exactly. Otherwise it taps the cue and
    /// pauses it once Syndicate reports it playing, learning where it is. A second press before the launch drops it.
    mutating func shiftPad(_ cue: Int, duration: Double?, now: Double) -> [Send] {
        if pending != nil { return endJump() }
        if let time = cueTimes[cue], let duration, duration > 0 {
            return [.hold(.cueJump), .osc("WaveformSeek", .float(Float(time / duration))), .release(.cueJump)]
        }
        pending = (cue, now)
        return [.hold(.cueJump), .osc("Cue\(cue)", .int(1))]
    }

    /// Syndicate's Playing. Playing: if it's the pad's launch, pause it there. Stopped: right after CUE while playing,
    /// it stopped on the cue point.
    mutating func playingChanged(_ playing: Bool, now: Double) -> [Send] {
        if playing {
            guard let pending else { return [] }
            guard now - pending.armedAt <= Self.cuePauseTimeout else { return endJump() }
            self.pending = nil
            learningCue = pending.cue
            return [.osc("Playing", .int(0)), .release(.cueJump)]
        }
        if let until = mainCueSettlesUntil, now <= until, let position { mainCue = position }
        return []
    }

    /// Syndicate's Position: the first after a pad's launch places that cue; after CUE while playing, the paused spot
    /// is the cue point.
    mutating func positionReported(_ seconds: Double, playing: Bool, now: Double) {
        if let cue = learningCue, playing {
            learningCue = nil
            cueTimes[cue] = max(0, seconds - Self.launchReportLead)
        }
        position = seconds
        guard !playing, let until = mainCueSettlesUntil else { return }
        mainCueSettlesUntil = nil
        if now <= until { mainCue = seconds }
    }

    /// Plain CUE pressed (Syndicate's own): its cue point is where the deck is paused, or, while playing, where it
    /// stops.
    mutating func cuePressed(playing: Bool, now: Double) {
        if playing { mainCueSettlesUntil = now + Self.mainCueSettle } else if let position { mainCue = position }
    }

    /// Shift + CUE on a paused deck: a WaveformSeek to the cue point, with quantize None so it lands there at once.
    /// Unknown, or already there: nothing, since Syndicate's Cue would make this spot the cue point.
    func shiftCue(duration: Double?) -> [Send] {
        guard let mainCue, let position, let duration, duration > 0, abs(position - mainCue) > Self.onCuePoint else { return [] }
        return [.hold(.returnToCue), .osc("WaveformSeek", .float(Float(mainCue / duration))), .release(.returnToCue)]
    }

    /// Drops a Shift + pad tap still waiting for its launch: the deck-lifecycle path, a second press, the timeout.
    mutating func endJump() -> [Send] {
        guard pending != nil else { return [] }
        pending = nil
        return [.release(.cueJump)]
    }

    /// A tap whose launch never came puts quantize back after the timeout.
    mutating func tick(now: Double) -> [Send] {
        guard let pending, now - pending.armedAt > Self.cuePauseTimeout else { return [] }
        return endJump()
    }

    /// A new track, or none: its cue times and cue point are unknown again.
    mutating func forgetTrack() -> [Send] {
        let sends = endJump()
        cueTimes = [:]
        mainCue = nil
        mainCueSettlesUntil = nil
        learningCue = nil
        return sends
    }
}
