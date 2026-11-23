import Foundation
@testable import ControllerBridgeCore
import Testing

/// The jog display's needle (#165, #215): Syndicate's master clock as a clock hand, one turn per bar, unless the
/// platter is moving, when it follows the platter. Sent as pitch bend, ⌊angle × 16384⌋. Worked by hand: at 120 BPM a
/// beat is 0.5 s and a bar of 4 is 2 s.
@Suite("Jog needle")
struct JogNeedleTests {
    @Test("Beat 1 at 120 BPM: 0 at the beat, an eighth of a turn (2048) a quarter-second on, and it waits at the beat's end (4096)")
    func clockHand() {
        var needle = JogNeedle()
        needle.beat(1, bpm: 120, at: 0)
        #expect(needle.pitchBend(at: 0) == 0)
        #expect(needle.pitchBend(at: 0.25) == 2048)
        #expect(needle.pitchBend(at: 0.5) == 4096)
        #expect(needle.pitchBend(at: 0.9) == 4096)   // the next beat hasn't come: it doesn't run ahead
    }

    @Test("Beat 2 starts the second quarter (4096); beat 4's end is the top again (0)")
    func laterBeats() {
        var needle = JogNeedle()
        needle.beat(2, bpm: 120, at: 10)
        #expect(needle.pitchBend(at: 10) == 4096)
        #expect(needle.pitchBend(at: 10.25) == 6144)
        needle.beat(4, bpm: 120, at: 11)
        #expect(needle.pitchBend(at: 11.5) == 0)
    }
}

/// The deck's own needle (#165, the user's pick): its phase in the bar from the deck's BarRamp, running on at the
/// deck's BPM between ramps (a bar of 4 beats is 240/bpm seconds), never more than a quarter turn past the last ramp.
@Suite("Jog needle from BarRamp")
struct JogNeedleRampTests {
    @Test("At the ramp, its phase: 0.5 is half a turn, 8192")
    func atRamp() {
        var needle = JogNeedle()
        needle.ramp(0.5, bpm: 120, at: 10)
        #expect(needle.pitchBend(at: 10) == 8192)
    }

    @Test("Between ramps it runs on at the deck's BPM: 120 BPM is a 2 s bar, so 0.25 s later is 1/8 turn more (2048)")
    func runsOn() {
        var needle = JogNeedle()
        needle.ramp(0.5, bpm: 120, at: 10)
        #expect(needle.pitchBend(at: 10.25) == 8192 + 2048)
    }

    @Test("No new ramp: it waits a quarter turn past the last one; a new ramp sets it again")
    func waits() {
        var needle = JogNeedle()
        needle.ramp(0.875, bpm: 120, at: 10)
        #expect(needle.pitchBend(at: 20) == 2048)          // 0.875 + 0.25 = 1.125, wrapped to 1/8 turn
        needle.ramp(0.25, bpm: 120, at: 20)
        #expect(needle.pitchBend(at: 20) == 4096)
    }

}
