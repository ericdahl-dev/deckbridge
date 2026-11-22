@testable import ControllerBridgeCore
import Testing

/// The jog display's beat clock (#720): the master clock's beat at any time, from the beat edges Syndicate sends. Ported
/// case by case from the deck panel's native tests (tools/deck-panel/test/test_beat_clock, #660 and #718), same numbers.
/// Times are the app clock's seconds; the cases are written in milliseconds, as the panel's are.
@Suite("Jog display beat clock")
struct BeatClockTests {
    /// `ms` milliseconds on the app clock, in its seconds.
    static func ms(_ ms: Double) -> Double { ms / 1000 }

    @Test("No beat heard: none")
    func noBeatHeardIsNone() {
        let clock = BeatClock()
        #expect(clock.beat(at: Self.ms(0)) == 0)
        #expect(clock.beat(at: Self.ms(10000)) == 0)
    }

    @Test("One edge gives no tempo: the beat heard holds until the next")
    func oneEdgeHoldsItsBeat() {
        var clock = BeatClock()
        clock.edge(3, at: Self.ms(100))
        #expect(clock.beat(at: Self.ms(100)) == 3)
        #expect(clock.beat(at: Self.ms(5000)) == 3)
    }

    @Test("Beat 0 is none")
    func beat0IsNone() {
        var clock = BeatClock()
        clock.edge(3, at: Self.ms(100))
        clock.edge(0, at: Self.ms(2200))
        #expect(clock.beat(at: Self.ms(2200)) == 0)
    }

    @Test("128 BPM: the next beat shows when due, before its message, and never two past the last edge")
    func nextBeatWhenDue() {
        var clock = BeatClock()
        clock.edge(1, at: Self.ms(1000))
        clock.edge(2, at: Self.ms(1469))
        #expect(clock.beat(at: Self.ms(1937)) == 2)
        #expect(clock.beat(at: Self.ms(1938)) == 3)
        #expect(BeatClock.predictBeats == 1)
        #expect(clock.beat(at: Self.ms(2407)) == 3)
        #expect(clock.beat(at: Self.ms(9000)) == 3)
    }

    @Test("After 4 comes 1")
    func after4Comes1() {
        var clock = BeatClock()
        clock.edge(3, at: Self.ms(1000))
        clock.edge(4, at: Self.ms(1469))
        #expect(clock.beat(at: Self.ms(1938)) == 1)
    }

    @Test("The same beat again (a repeat) is no edge, so no tempo from it")
    func sameBeatAgainIsNoEdge() {
        var clock = BeatClock()
        clock.edge(1, at: Self.ms(1000))
        clock.edge(1, at: Self.ms(1200))
        clock.edge(2, at: Self.ms(1469))
        #expect(clock.beat(at: Self.ms(1938)) == 3)
    }

    /// The first millisecond `clock` shows `beat` from `from` to `to` (both ms), scanning each; nil if it never does.
    static func firstShows(_ clock: BeatClock, _ beat: Int, from: Int, to: Int) -> Int? {
        (from...to).first { clock.beat(at: ms(Double($0))) == beat }
    }

    /// `beat` (1-4) `k` beats after `first`.
    static func beat(_ k: Int, after first: Int = 1) -> Int { (first - 1 + k) % 4 + 1 }

    @Test("Arrivals jitter up to 10 ms either way: after 16 edges at 128 BPM the next beat shows within 4 ms of due")
    func jitteredEdgesLock() throws {
        let jitter = [6, -9, 3, 10, -4, -10, 8, 0, -6, 9, -2, 5, -8, 2, 7, -7]
        var clock = BeatClock()
        for k in 0..<16 {
            clock.edge(Self.beat(k), at: Self.ms((1000 + Double(k) * 468.75 + Double(jitter[k])).rounded()))
        }
        let shown = try #require(Self.firstShows(clock, Self.beat(16), from: 8300, to: 8700))
        #expect(abs(shown - 8500) <= 4)
    }

    @Test("One message 30 ms late doesn't drag the next beat 30 ms late with it")
    func oneLateMessage() throws {
        var clock = BeatClock()
        for k in 0..<8 {
            clock.edge(Self.beat(k), at: Self.ms((1000 + Double(k) * 468.75).rounded() + (k == 7 ? 30 : 0)))
        }
        let shown = try #require(Self.firstShows(clock, Self.beat(8), from: 4600, to: 4900))
        #expect(abs(shown - 4750) <= 10)
    }

    @Test("A quiet feed: the clock holds, never more than one beat past the last edge")
    func quietFeedHolds() {
        var clock = BeatClock()
        clock.edge(1, at: Self.ms(1000))
        clock.edge(2, at: Self.ms(1469))
        for t in stride(from: 1469, to: 20000, by: 50) {
            #expect([2, 3].contains(clock.beat(at: Self.ms(Double(t)))))
        }
    }

    @Test("Beats after a gap start the clock over: the first back shows as heard, not run on from before")
    func gapStartsOver() {
        var clock = BeatClock()
        clock.edge(1, at: Self.ms(1000))
        clock.edge(2, at: Self.ms(1469))
        clock.edge(3, at: Self.ms(6000))  // the next value, but 4.5 s on
        #expect(clock.beat(at: Self.ms(6000)) == 3)
        #expect(clock.beat(at: Self.ms(6400)) == 3)
        #expect(clock.beat(at: Self.ms(7000)) == 3)  // no tempo yet: one edge back
        clock.edge(4, at: Self.ms(6469))
        #expect(clock.beat(at: Self.ms(6938)) == 1)
    }

    /// 8 beats in time at 128 BPM from 1000 ms: the last (beat 4) at 4281.
    static func locked() -> BeatClock {
        var clock = BeatClock()
        for k in 0..<8 { clock.edge(beat(k), at: ms((1000 + Double(k) * 468.75).rounded())) }
        return clock
    }

    @Test("A cue jump on the master: a beat out of turn shows at once, and the tempo holds")
    func outOfTurnKeepsTempo() throws {
        var clock = Self.locked()
        clock.edge(3, at: Self.ms(4500))  // 2 was next, at 4750
        #expect(clock.beat(at: Self.ms(4500)) == 3)
        let shown = try #require(Self.firstShows(clock, 4, from: 4500, to: 5200))
        #expect(abs(shown - 4969) <= 3)
    }

    @Test("A loop wrapping on the master: the next beat far off the grid moves the clock at once, tempo held")
    func farOffGridSnaps() throws {
        var clock = Self.locked()
        clock.edge(1, at: Self.ms(4600))  // due at 4750
        #expect(clock.beat(at: Self.ms(4600)) == 1)
        let shown = try #require(Self.firstShows(clock, 2, from: 4600, to: 5400))
        #expect(abs(shown - 5069) <= 3)
    }

    @Test("With the master clock's BPM, one edge is enough: the next is due a beat length on")
    func bpmOneEdge() {
        var clock = BeatClock()
        clock.setTempo(128)
        clock.edge(1, at: Self.ms(1000))
        #expect(clock.beat(at: Self.ms(1468)) == 1)
        #expect(clock.beat(at: Self.ms(1469)) == 2)
    }

    @Test("The BPM gives the beat length: jittered edges move only the beat's place")
    func bpmJitterKeepsLength() throws {
        var clock = BeatClock()
        clock.setTempo(128)
        let jitter = [0, 9, 9, 9, 9, 9, 9, 9]  // late every time but the first
        for k in 0..<8 { clock.edge(Self.beat(k), at: Self.ms((1000 + Double(k) * 468.75 + Double(jitter[k])).rounded())) }
        let shown = try #require(Self.firstShows(clock, Self.beat(8), from: 4400, to: 5000))
        #expect(abs(shown - 4759) <= 4)
    }

    @Test("A tempo change on the master applies at once: the next beat is due at the new length")
    func bpmChangeAtOnce() throws {
        var clock = Self.locked()  // 128 BPM from the edges; the last, beat 4, at 4281
        clock.setTempo(120)        // 500 ms
        let shown = try #require(Self.firstShows(clock, 1, from: 4281, to: 5000))
        #expect(abs(shown - 4781) <= 2)
    }

    @Test("BPM 0 is none: the edges give the beat length again")
    func bpm0LeavesItToEdges() {
        var clock = BeatClock()
        clock.setTempo(0)
        clock.edge(1, at: Self.ms(1000))
        #expect(clock.beat(at: Self.ms(1600)) == 1)  // one edge, no length
        clock.edge(2, at: Self.ms(1469))
        #expect(clock.beat(at: Self.ms(1938)) == 3)
    }

    @Test("The BPM just after the first edge times that beat too")
    func bpmJustAfterFirstEdge() {
        var clock = BeatClock()
        clock.edge(1, at: Self.ms(1000))
        clock.setTempo(128)
        #expect(clock.beat(at: Self.ms(1469)) == 2)
    }

    @Test("Stopped, a BPM doesn't start the clock again: only beats do")
    func bpmAfterStopDoesntRestart() {
        var clock = Self.locked()
        clock.stop()
        clock.setTempo(120)
        #expect(clock.beat(at: Self.ms(6000)) == 4)
    }
}
