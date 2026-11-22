// The jog display's marker (#165, #215): one hand on the platter display, moved by pitch bend on the WD port.
// It shows the deck's own phase in the bar, one turn per bar of four beats, from the deck's BarRamp and BPM (the
// user's pick: the needle is the deck, the lit ring segment is the master). The master-clock mode stays for #215.
// The platter never moves it (the user's pick for v1.1, reversing #306): a seek on a paused deck moves the deck's
// BarRamp, which it follows.

public struct JogMarker: Equatable, Sendable {
    private enum Mode: Equatable, Sendable {
        /// The clock hand: `base` turns at `since`, running a quarter turn per beat at `bpm`, but never past the beat.
        case clock(base: Double, since: Double, bpm: Double)
        /// The deck's phase: `phase` turns at `since`, running on at `bpm`, never more than a quarter turn past it.
        case ramp(phase: Double, since: Double, bpm: Double)
        /// Stopped where the deck paused.
        case held(Double)
    }

    private var mode = Mode.held(0)

    public init() {}

    /// Syndicate's master clock reached `beat` (1-4) of the bar at `bpm`.
    public mutating func beat(_ beat: Int, bpm: Double, at time: Double) {
        mode = .clock(base: Double(max(1, min(4, beat)) - 1) / 4, since: time, bpm: bpm)
    }

    /// The deck's BarRamp said it's `phase` (0..1) of the way through its bar, at `bpm`.
    public mutating func ramp(_ phase: Double, bpm: Double, at time: Double) {
        mode = .ramp(phase: phase, since: time, bpm: bpm)
    }

    /// The deck stopped: the hand stays where it is at `time`.
    public mutating func freeze(at time: Double) {
        mode = .held(angle(at: time))
    }

    /// The hand's angle in turns at `time`, not yet wrapped.
    func angle(at time: Double) -> Double {
        switch mode {
        case .held(let angle): angle
        case .clock(let base, let since, let bpm), .ramp(let base, let since, let bpm):
            base + min(max(0, time - since) * bpm / 240, 0.25)
        }
    }

    /// The pitch bend that draws it: ⌊angle × 16384⌋, wrapped to 0...16383.
    public func pitchBend(at time: Double) -> Int {
        let turns = angle(at: time)
        let wrapped = turns - turns.rounded(.down)
        return Int((wrapped * 16384).rounded(.down)) & 0x3FFF
    }
}
