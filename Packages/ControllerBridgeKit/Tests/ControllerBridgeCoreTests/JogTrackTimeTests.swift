@testable import ControllerBridgeCore
import Testing

/// The last minute's warning (#460, #524), the user's pick: while playing, the remaining time and the progress ring
/// turn steady red (0xFF3B30) from 60 s left, and from 30 s blink at 1 Hz between red and white (0xEDEDEA), whatever
/// the deck color. `phase` is the time since the shown second last changed, 0 to 1: red in its first half, so the
/// color flips on the frame the digit changes.
@Suite("Jog display: track time warning")
struct JogTrackTimeTests {
    @Test("Above 60 s left: normal")
    func normal() {
        #expect(JogTrackTime.look(elapsed: 59, length: 120, playing: true, looping: false, phase: 0) == .normal)
    }

    @Test("From 60 s to 31 s left: steady red, whatever the phase")
    func steadyRed() {
        for elapsed in [60, 89] {
            for phase in [0, 0.2, 0.7, 0.99] {
                #expect(JogTrackTime.look(elapsed: elapsed, length: 120, playing: true, looping: false, phase: phase) == .warningRed)
            }
        }
    }

    @Test("From 30 s left to the end: red from each second's change, white in its second half")
    func blinks() {
        for elapsed in [90, 120] {
            #expect(JogTrackTime.look(elapsed: elapsed, length: 120, playing: true, looping: false, phase: 0) == .warningRed)
            #expect(JogTrackTime.look(elapsed: elapsed, length: 120, playing: true, looping: false, phase: 0.49) == .warningRed)
            #expect(JogTrackTime.look(elapsed: elapsed, length: 120, playing: true, looping: false, phase: 0.5) == .warningWhite)
        }
    }

    @Test("Paused, or an unknown length: normal")
    func notWhen() {
        #expect(JogTrackTime.look(elapsed: 70, length: 120, playing: false, looping: false, phase: 0.2) == .normal)
        #expect(JogTrackTime.look(elapsed: 100, length: 120, playing: false, looping: false, phase: 0.7) == .normal)
        #expect(JogTrackTime.look(elapsed: 100, length: 0, playing: true, looping: false, phase: 0.2) == .normal)
    }

    /// The user's pick: a loop holds the warning. While the deck's loop is on, no red, steady or blinking; it comes
    /// back when the loop is released.
    @Test("Looping: normal, whatever the time left; released: the warning again")
    func loopHolds() {
        for elapsed in [70, 100] {
            for phase in [0.2, 0.7] {
                #expect(JogTrackTime.look(elapsed: elapsed, length: 120, playing: true, looping: true, phase: phase) == .normal)
            }
        }
        #expect(JogTrackTime.look(elapsed: 100, length: 120, playing: true, looping: false, phase: 0.2) == .warningRed)
    }
}
