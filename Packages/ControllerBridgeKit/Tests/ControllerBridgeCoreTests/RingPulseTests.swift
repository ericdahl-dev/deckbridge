import ControllerBridgeCore
import Foundation
import Testing

/// The ring's smooth beat pulse (#533), the user's pick: with the color message on and the beat pulse on, the ring is
/// full on each beat of Syndicate's master clock and eases down to about 25% by the next beat (the beat's length from
/// the master BPM), never dark, in the deck's exact hue. Ease: 25% + 75% × (1 − p)², p the part of the beat gone.
/// Messages at most `Bridge.pulseRate` a second. Deck 1's color is Syndicate's factory red, 255, 0, 0.
@Suite("Ring: smooth beat pulse")
struct RingPulseTests {
    final class PulseRig {
        let midi = Rig.FakeMIDISystem(sources: [Rig.lc6000], destinations: [Rig.lc6000Out])
        let clock = Rig.FakeClock()
        let coordinator: Coordinator

        init(beatPulse: String = "beat", colorMessages: Bool = true) throws {
            let override = Data(#"{ "leds": { "beat_pulse": "\#(beatPulse)" } }"#.utf8)
            coordinator = Coordinator(mapping: try Mapping.bundledDefault(overriddenBy: override),
                                      midi: midi, osc: Rig.FakeOSC(), clock: clock, log: Rig.FakeLog())
            coordinator.start()
            coordinator.setColorMessages(colorMessages)
            coordinator.feedback(OSCMessage("/Syndicate/Header/BPM", [.float(120)]))
            coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        }

        var output: Rig.FakeOutput { midi.outputs[Rig.lc6000Out.id]! }

        /// The ring's red channel as last sent by color message, after a tick at `time`.
        func red(at time: Double) -> UInt8? {
            clock.now = time
            coordinator.tick()
            return output.colors.last { $0.note == 40 }?.red
        }

        func beat(_ beat: Int32, at time: Double) {
            clock.now = time
            coordinator.feedback(OSCMessage("/Syndicate/Header/Clock", [.int(beat)]))
        }
    }

    @Test("Full on the beat; at half the beat (0.25 s at 120 BPM) 25% + 75% × 0.25 = 43.75%: 255 → 111 → 55")
    func fullThenEases() throws {
        let rig = try PulseRig()
        rig.beat(1, at: 10)
        #expect(rig.red(at: 10) == 127)
        #expect(rig.red(at: 10.25) == 55)
    }

    @Test("Never dark: by the next beat, and on with no beat since, it rests at 25%: 255 → 63 → 31")
    func restsAtAQuarter() throws {
        let rig = try PulseRig()
        rig.beat(1, at: 10)
        #expect(rig.red(at: 10.49) == 31)
        #expect(rig.red(at: 10.8) == 31)
        rig.beat(2, at: 10.9)
        #expect(rig.red(at: 10.9) == 127)
    }

    @Test("At most 30 messages a second: a second of 10 ms ticks over two beats sends no more than 30, and more than 10")
    func capped() throws {
        let rig = try PulseRig()
        rig.output.colors.removeAll()
        for step in 0..<100 {
            let time = 10 + Double(step) * 0.01
            if step % 50 == 0 { rig.beat(Int32(step / 50 + 1), at: time) }
            _ = rig.red(at: time)
        }
        let sent = rig.output.colors.filter { $0.note == 40 }.count
        #expect(sent <= 30 && sent > 10)
    }

    @Test("Pulse off: master clock beats leave the ring steady, one message in its full color")
    func offIsSteady() throws {
        let rig = try PulseRig(beatPulse: "off")
        rig.output.colors.removeAll()
        rig.beat(1, at: 10)
        _ = rig.red(at: 10)
        _ = rig.red(at: 10.25)
        rig.beat(2, at: 10.5)
        _ = rig.red(at: 10.5)
        #expect(rig.output.colors.filter { $0.note == 40 }.isEmpty)
        #expect(rig.red(at: 11) == nil)
    }

    @Test("The clock stops for more than 2 s: the ring goes back to steady full")
    func clockStops() throws {
        let rig = try PulseRig()
        rig.beat(1, at: 10)
        #expect(rig.red(at: 10.3) != 127)
        #expect(rig.red(at: 12.6) == 127)
    }
}
