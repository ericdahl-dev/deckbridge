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
}
