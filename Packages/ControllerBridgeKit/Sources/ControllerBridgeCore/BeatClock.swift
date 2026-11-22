// The jog display's beat clock (#720): the master clock's beat (1-4) at any time, from the beat edges Syndicate sends,
// so the jog display's beat goes when it's due, not when a message happens to arrive. The deck panel's model (#660,
// #718, tools/deck-panel/lib/deck_core/beat_clock.cpp), on the app clock's seconds.

struct BeatClock {
    /// How many beats past the last edge heard the clock shows when they're due: the panel's 1 (the owner's pick,
    /// 2026-11-21). The next beat goes on time, and if the master stops, at most one shows that didn't happen.
    static let predictBeats = 1
    /// Tempos the clock believes, as a beat's length: 40-300 BPM.
    static let shortestBeat = 0.2, longestBeat = 1.5
    /// A boundary hit exactly is the beat's: times are sums of seconds, so allow for their rounding.
    private static let epsilon = 1e-9

    /// The last beat heard; 0 for none.
    private var beat = 0
    /// When it's taken to have started.
    private var edgeAt = 0.0
    /// A beat's length; 0 until two edges in a row give it.
    private var period = 0.0

    /// Syndicate's beat arrived at `at`: a new value is an edge; the same again is none.
    mutating func edge(_ beat: Int, at: Double) {
        guard (1...4).contains(beat) else {
            self.beat = 0
            period = 0
            return
        }
        guard beat != self.beat else { return }
        let sinceLast = at - edgeAt
        if self.beat == 0 || beat != Self.next(self.beat) {
            self.beat = beat
            edgeAt = at
            period = 0
            return
        }
        self.beat = beat
        if period == 0, sinceLast >= Self.shortestBeat - Self.epsilon, sinceLast <= Self.longestBeat + Self.epsilon {
            period = sinceLast
        }
        edgeAt = at
    }

    /// The beat to show at `now`, 1-4; 0 for none.
    func beat(at now: Double) -> Int {
        guard beat != 0, period > 0 else { return beat }
        let since = now - edgeAt
        guard since > 0 else { return beat }
        let ahead = min(Int(((since + Self.epsilon) / period).rounded(.down)), Self.predictBeats)
        var shown = beat
        for _ in 0..<ahead { shown = Self.next(shown) }
        return shown
    }

    static func next(_ beat: Int) -> Int { beat % 4 + 1 }
}
