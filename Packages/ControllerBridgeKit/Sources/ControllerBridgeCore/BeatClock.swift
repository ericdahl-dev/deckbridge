// The jog display's beat clock (#720): the master clock's beat (1-4) at any time, from the beat edges Syndicate sends,
// so the jog display's beat goes when it's due, not when a message happens to arrive. The deck panel's model (#660,
// #718, tools/deck-panel/lib/deck_core/beat_clock.cpp), on the app clock's seconds.

struct BeatClock {
    /// How many beats past the last edge heard the clock shows when they're due: the panel's 1 (the owner's pick,
    /// 2026-11-21). The next beat goes on time, and if the master stops, at most one shows that didn't happen.
    static let predictBeats = 1
    /// Tempos the clock believes, as a beat's length: 40-300 BPM.
    static let shortestBeat = 0.2, longestBeat = 1.5
    /// The lock (#660): arrivals jitter by a few ms (USB, Syndicate), so each edge moves the clock only part of the way:
    /// `phaseGain` of its error, and the tempo `tempoGain` of it, each error clipped to `maxError` so one late message
    /// barely moves the next beat. The first `averagedEdges` beats set the tempo as an average since the first. The
    /// panel's numbers, tuned in a simulation of +-10 ms jitter at 128 BPM.
    static let phaseGain = 0.25, tempoGain = 0.05, maxError = 0.010
    static let averagedEdges = 4
    /// An edge more than this many beats after the last starts the clock over: a gap, not a beat.
    static let gapBeats = 1.5
    /// An edge further than this off the grid isn't jitter: the clock moves to it at once, keeping the tempo.
    static let snapDistance = 0.040
    /// A boundary hit exactly is the beat's: times are sums of seconds, so allow for their rounding.
    private static let epsilon = 1e-9

    /// The longest lead (cos, #720): the jog display's path (USB, the chip's draw) may need more than the panel's 99 ms.
    /// Past half a beat the beat just heard shows only briefly, and past a whole beat (200 ms at 300 BPM) not at all.
    static let longestLead = 0.200
    /// Each beat shows this long before it's due, so it lands with Syndicate's click, not the path's delay behind it.
    let lead: Double

    /// `lead`: seconds, kept to 0...`longestLead`.
    init(lead: Double = 0) {
        self.lead = min(max(lead, 0), Self.longestLead)
    }

    /// The last beat heard; 0 for none.
    private var beat = 0
    /// When it's taken to have started.
    private var edgeAt = 0.0
    /// A beat's length; 0 until two edges in a row give it.
    private var period = 0.0
    /// The first edge of this run of beats in a row, and how many beats in a row since.
    private var firstAt = 0.0
    private var edges = 0
    /// A beat's length from the master clock's BPM; 0 for none.
    private var tempo = 0.0
    /// stop() since the last edge: nothing ahead until beats come again.
    private var stopped = false

    /// Syndicate's beat arrived at `at`: a new value is an edge; the same again is none.
    mutating func edge(_ beat: Int, at: Double) {
        guard (1...4).contains(beat) else {
            self.beat = 0
            period = 0
            return
        }
        guard beat != self.beat else { return }
        stopped = false
        let sinceLast = at - edgeAt
        // Too long since the last for one beat: a gap (the master stopped, or the feedback went quiet), not a length.
        let gap = sinceLast > (period > 0 ? Self.gapBeats * period : Self.longestBeat)
        if self.beat != 0, !gap, period > 0, beat != Self.next(self.beat) {
            return snap(beat, at: at)  // out of turn: a cue jump on the master
        }
        if self.beat == 0 || beat != Self.next(self.beat) || gap {
            // A first beat, or not the next one: a new run starts here.
            self.beat = beat
            edgeAt = at
            firstAt = at
            edges = 0
            period = tempo  // known from the BPM, or 0 until the next edge
            return
        }
        self.beat = beat
        edges += 1
        guard period > 0 else {
            if sinceLast >= Self.shortestBeat - Self.epsilon, sinceLast <= Self.longestBeat + Self.epsilon { period = sinceLast }
            edgeAt = at
            return
        }
        guard abs(sinceLast - period) <= Self.snapDistance else {
            return snap(beat, at: at)  // in turn but far off the grid: a loop wrapping, a jump
        }
        let error = min(max(sinceLast - period, -Self.maxError), Self.maxError)
        edgeAt += period + Self.phaseGain * error
        if tempo > 0 {
            period = tempo  // the BPM's, never the edges'
        } else if edges <= Self.averagedEdges {
            period = (at - firstAt) / Double(edges)
        } else {
            period += Self.tempoGain * error
        }
    }

    /// The master clock's BPM (Syndicate's header BPM): with it, a beat's length is known from the first edge and only
    /// the beat's place is locked; a change applies at once. 0 (or out of range) is none: the edges give it.
    mutating func setTempo(_ bpm: Double) {
        let length = bpm > 0 ? 60 / bpm : 0
        tempo = length >= Self.shortestBeat && length <= Self.longestBeat ? length : 0
        // A beat heard and not stopped: the new length from now, the first edge's too. Stopped, the next edge takes it.
        if tempo > 0, beat != 0, !stopped { period = tempo }
    }

    /// The master stopped: show the beat heard, nothing ahead, until beats come again.
    mutating func stop() {
        period = 0
        stopped = true
    }

    /// The beat as heard, from now; the tempo holds, and from here on only the lock moves it.
    private mutating func snap(_ beat: Int, at: Double) {
        self.beat = beat
        edgeAt = at
        edges = max(edges, Self.averagedEdges)
    }

    /// The beat to show at `now`, 1-4; 0 for none.
    func beat(at now: Double) -> Int {
        guard beat != 0, period > 0 else { return beat }
        let since = now + lead - edgeAt
        guard since > 0 else { return beat }
        let ahead = min(Int(((since + Self.epsilon) / period).rounded(.down)), Self.predictBeats)
        var shown = beat
        for _ in 0..<ahead { shown = Self.next(shown) }
        return shown
    }

    static func next(_ beat: Int) -> Int { beat % 4 + 1 }
}
