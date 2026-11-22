import Foundation
import ControllerBridgeCore
import Testing

/// Pitch fader, jog and Needle Drop. Expected values come from the Python bridge's tests and codec.
@Suite("Continuous controls")
struct ContinuousTests {
    static func started(_ override: String? = nil) throws -> Rig {
        let rig = try Rig(override: override)
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        return rig
    }

    static func cc(_ rig: Rig, _ controller: UInt8, _ value: UInt8) {
        rig.coordinator.midi(.controlChange(channel: 0, controller: controller, value: value), source: Rig.lc6000.id)
    }

    @Test("The 14-bit pitch fader sends TempoSlider as a float; a repeated value isn't resent")
    func pitchFader14Bit() throws {
        let rig = try Self.started()
        Self.cc(rig, 8, 0x7F)
        Self.cc(rig, 40, 0x7F)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/TempoSlider", [.float(1.0)]))
        let count = rig.osc.sent.count
        Self.cc(rig, 40, 0x7F)
        #expect(rig.osc.sent.count == count)
    }

    @Test("Fader bottom is -1.0; the center (0x40/0x00) snaps to 0.0 inside the dead zone")
    func pitchEndsAndCenter() throws {
        let rig = try Self.started()
        Self.cc(rig, 8, 0x40)
        Self.cc(rig, 40, 0x00)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/TempoSlider", [.float(0.0)]))
        Self.cc(rig, 8, 0x00)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/TempoSlider", [.float(-1.0)]))
    }

    @Test("pitch.invert flips the direction: fader top sends -1.0")
    func pitchInvert() throws {
        let rig = try Self.started(#"{ "pitch": { "invert": true } }"#)
        Self.cc(rig, 8, 0x7F)
        Self.cc(rig, 40, 0x7F)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/TempoSlider", [.float(-1.0)]))
    }

    static func feedback(_ rig: Rig, _ path: String, _ arguments: [OSCArgument]) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/" + path, arguments))
    }

    // MARK: The jog, as the real LC6000 sends it (#103): a 14-bit platter position on CC 17 (MSB) then CC 49 (LSB)

    /// The platter at `position` (0-16383): the MSB, then the LSB, as the hardware sends them.
    static func platterAt(_ rig: Rig, _ position: Int) {
        cc(rig, 17, UInt8(position >> 7))
        cc(rig, 49, UInt8(position & 0x7F))
    }

    @Test("Playing, the captured positions 0/79, 0/86, 0/94 nudge forward once; going back nudges back")
    func jogPositionBends() throws {
        let rig = try Self.started()
        Self.feedback(rig, "Playing", [.int(1)])
        Self.cc(rig, 17, 0); Self.cc(rig, 49, 79)   // the first position: nothing to compare yet
        Self.cc(rig, 17, 0); Self.cc(rig, 49, 86)
        Self.cc(rig, 17, 0); Self.cc(rig, 49, 94)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)])])
        Self.cc(rig, 17, 0); Self.cc(rig, 49, 86)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(-1)]))
    }

    @Test("A carry into the MSB (0/120, 0/127, 1/1) is still forward: the position is read when the LSB arrives")
    func jogMSBCarry() throws {
        let rig = try Self.started()
        Self.feedback(rig, "Playing", [.int(1)])
        Self.cc(rig, 17, 0); Self.cc(rig, 49, 120)
        Self.cc(rig, 17, 0); Self.cc(rig, 49, 127)
        Self.cc(rig, 17, 1); Self.cc(rig, 49, 1)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)])])
    }

    @Test("Crossing the wrap (127/120 = 16376, then 0/3 = 3) is 11 forward, not 16373 back")
    func jogWrap() throws {
        let rig = try Self.started()
        Self.feedback(rig, "Playing", [.int(1)])
        Self.cc(rig, 17, 127); Self.cc(rig, 49, 120)
        Self.cc(rig, 17, 0); Self.cc(rig, 49, 3)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)])])
        Self.cc(rig, 17, 127); Self.cc(rig, 49, 120)   // and back across it
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(-1)]))
    }

    @Test("While playing, PhaseBend 0 follows 80 ms after the wheel stops")
    func jogBendThenRelease() throws {
        let rig = try Self.started()
        Self.feedback(rig, "Playing", [.int(1)])
        Self.platterAt(rig, 1000)
        Self.platterAt(rig, 1008)
        rig.clock.now = 0.05
        rig.coordinator.tick()
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)])])
        rig.clock.now = 0.2
        rig.coordinator.tick()
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)]))
        #expect(rig.osc.sent.count == 2)
    }

    @Test("The nudge is a held control: release-all sends PhaseBend 0 once, and the next turn nudges afresh")
    func bendIsHeld() throws {
        let rig = try Self.started()
        Self.feedback(rig, "Playing", [.int(1)])
        Self.platterAt(rig, 1000)
        Self.platterAt(rig, 1008)
        rig.osc.sent.removeAll()

        rig.coordinator.willSleep()   // release-all, ports left open
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)])])

        Self.platterAt(rig, 1016)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)]))

        rig.osc.sent.removeAll()
        rig.coordinator.willSleep()   // release-all, ports left open
        rig.clock.now = 1
        rig.coordinator.tick()
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)])])
    }

    @Test("Syndicate reporting Playing 0 ends the nudge with PhaseBend 0")
    func stopPlayingEndsBend() throws {
        let rig = try Self.started()
        Self.feedback(rig, "Playing", [.int(1)])
        Self.platterAt(rig, 1000)
        Self.platterAt(rig, 1008)
        Self.feedback(rig, "Playing", [.int(0)])
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)]))
        #expect(rig.osc.sent.count == 2)
    }

    @Test("Letting go of the platter ends the nudge with PhaseBend 0")
    func platterReleaseEndsBend() throws {
        let rig = try Self.started()
        Self.feedback(rig, "Playing", [.int(1)])
        rig.coordinator.midi(.noteOn(channel: 0, note: 40, velocity: 127), source: Rig.lc6000.id)
        Self.platterAt(rig, 1000)
        Self.platterAt(rig, 1008)
        rig.coordinator.midi(.noteOff(channel: 0, note: 40, velocity: 0), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)]),
        ])
    }

    /// 1000 counts a turn, a turn seeks 4 s or skips 4 beats: easy numbers to check by hand.
    static let scaled = #"{ "jog": { "counts_per_rev": 1000, "seek_seconds_per_rev": 4, "beats_per_rev": 4 } }"#

    @Test("Paused, half a turn (500 of 1000 counts) seeks half of seek_seconds_per_rev: 2 s of 200 s, from 0.5 to 0.51")
    func jogSeeksWhilePaused() throws {
        let rig = try Self.started(Self.scaled)
        Self.feedback(rig, "TrackInfo", [.string("t"), .string("a"), .string("8A"), .float(120), .float(200), .int(100), .int(400), .string("track")])
        Self.feedback(rig, "Progress", [.float(0.5)])
        Self.platterAt(rig, 2000)
        Self.platterAt(rig, 2500)
        guard case .float(let position)? = rig.osc.sent.last?.arguments.first else {
            Issue.record("expected a float WaveformSeek, got \(rig.osc.sent)")
            return
        }
        #expect(rig.osc.sent.last?.address == "/Syndicate/Deck/1/WaveformSeek")
        #expect(abs(position - 0.51) < 0.000_01)
    }

    @Test("Paused with no track length, a quarter turn (250 of 1000 counts, 4 beats a turn) skips one beat")
    func jogFallsBackToBeatSkip() throws {
        let rig = try Self.started(Self.scaled)
        Self.platterAt(rig, 2000)
        Self.platterAt(rig, 2125)
        #expect(rig.osc.sent == [])                   // an eighth of a turn: not a beat yet
        Self.platterAt(rig, 2250)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/BeatSkip", [.int(1)])])
        Self.platterAt(rig, 2000)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/BeatSkip", [.int(-1)]))
        #expect(rig.osc.sent.count == 2)
    }

    // MARK: Needle Drop: a 14-bit position on CC 64 (MSB) then CC 65 (LSB) (#103)

    static func strip(_ rig: Rig, _ msb: UInt8, _ lsb: UInt8) {
        cc(rig, 64, msb)
        cc(rig, 65, lsb)
    }

    @Test("Shift + Needle Drop seeks only while the strip is touched: 127/127 seeks to the end, 64/0 just past the middle")
    func needleSeeksWhileTouched() throws {
        let rig = try Self.started()
        Self.strip(rig, 64, 0)
        #expect(rig.osc.sent == [])
        rig.coordinator.midi(.noteOn(channel: 0, note: 26, velocity: 127), source: Rig.lc6000.id)   // Shift: seek (#729)
        rig.coordinator.midi(.noteOn(channel: 0, note: 70, velocity: 127), source: Rig.lc6000.id)
        Self.strip(rig, 127, 127)
        Self.strip(rig, 64, 0)   // 8192 / 16383
        // The deck is paused, so the seeks also hold its quantize at None (#366, JogQuantizeTests); only the seeks here.
        let seeks = { rig.osc.sent.filter { $0.address.hasSuffix("/WaveformSeek") } }
        #expect(seeks() == [
            OSCMessage("/Syndicate/Deck/1/WaveformSeek", [.float(1.0)]),
            OSCMessage("/Syndicate/Deck/1/WaveformSeek", [.float(0.500_030_5)]),
        ])
        rig.coordinator.midi(.noteOff(channel: 0, note: 70, velocity: 0), source: Rig.lc6000.id)
        Self.strip(rig, 0, 0)
        #expect(seeks().count == 2)
    }

    @Test("Release-all clears the needle touch: afterwards, moving the strip seeks nothing")
    func releaseAllClearsNeedleTouch() throws {
        let rig = try Self.started()
        rig.coordinator.midi(.noteOn(channel: 0, note: 70, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.willSleep()   // release-all, ports left open
        Self.strip(rig, 100, 0)
        #expect(rig.osc.sent == [])
    }

    @Test("With jog.require_touch, the jog acts only while the platter is touched, and release-all clears the touch")
    func releaseAllClearsPlatterTouch() throws {
        let rig = try Self.started(#"{ "jog": { "require_touch": true } }"#)
        Self.feedback(rig, "Playing", [.int(1)])
        Self.platterAt(rig, 1000)
        Self.platterAt(rig, 1008)
        #expect(rig.osc.sent == [])

        rig.coordinator.midi(.noteOn(channel: 0, note: 40, velocity: 127), source: Rig.lc6000.id)
        Self.platterAt(rig, 1016)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)])])

        rig.coordinator.willSleep()   // release-all, ports left open
        rig.osc.sent.removeAll()
        Self.platterAt(rig, 1024)
        #expect(rig.osc.sent == [])
    }

    @Test("The pitch center LED is full while the last tempo sent is 0.0, and off otherwise")
    func pitchCenterLED() throws {
        let rig = try Self.started()
        #expect(rig.leds[42] == 0)
        Self.cc(rig, 8, 0x40)
        Self.cc(rig, 40, 0x00)
        #expect(rig.leds[42] == 127)
        Self.cc(rig, 8, 0x50)
        #expect(rig.leds[42] == 0)
    }

    @Test("Loaded 0 forgets the track's progress and length: a paused jog then falls back to BeatSkip")
    func unloadForgetsTrack() throws {
        let rig = try Self.started(Self.scaled)
        Self.feedback(rig, "Loaded", [.int(1)])
        Self.feedback(rig, "TrackInfo", [.string("t"), .string("a"), .string("8A"), .float(120), .float(200), .int(100), .int(400), .string("track")])
        Self.feedback(rig, "Progress", [.float(0.5)])
        Self.feedback(rig, "Loaded", [.int(0)])
        Self.platterAt(rig, 2000)
        Self.platterAt(rig, 2250)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/BeatSkip", [.int(1)])])
    }

    @Test("A hand-built mapping with 0 counts per turn doesn't crash a paused jog: it moves nothing (#92)")
    func zeroCountsPerRev() throws {
        var mapping = try Mapping.bundledDefault()
        mapping.jog?.countsPerRev = 0
        let rig = try Rig()
        let coordinator = Coordinator(mapping: mapping, midi: rig.midi, osc: rig.osc, clock: rig.clock, log: rig.log)
        coordinator.start()
        rig.osc.sent.removeAll()
        for (msb, lsb) in [(UInt8(7), UInt8(0)), (7, 100)] {
            coordinator.midi(.controlChange(channel: 0, controller: 17, value: msb), source: Rig.lc6000.id)
            coordinator.midi(.controlChange(channel: 0, controller: 49, value: lsb), source: Rig.lc6000.id)
        }
        #expect(rig.osc.sent == [])
    }

    @Test("Measured on the unit: (10,62)→(10,64) is 2 counts forward; (38,3)→(37,0) is 131 back, about 0.15 s with the measured 3600 a turn")
    func measuredCounts() throws {
        let rig = try Self.started(#"{ "jog": { "seek_seconds_per_rev": 4 } }"#)
        Self.feedback(rig, "TrackInfo", [.string("t"), .string("a"), .string("8A"), .float(120), .float(200), .int(100), .int(400), .string("track")])
        Self.feedback(rig, "Progress", [.float(0.5)])
        Self.cc(rig, 17, 10); Self.cc(rig, 49, 62)
        Self.cc(rig, 17, 10); Self.cc(rig, 49, 64)
        // +2 of 3600 a turn × 4 s a turn = 0.00222 s; of 200 s = +0.0000111.
        Self.cc(rig, 17, 38); Self.cc(rig, 49, 3)    // a jump: 4867 - 1344 = 3523 forward
        rig.osc.sent.removeAll()
        Self.cc(rig, 17, 37); Self.cc(rig, 49, 0)
        // -131 / 3600 × 4 s = -0.14556 s; of 200 s = -0.00072778.
        guard case .float(let before)? = rig.osc.sent.last?.arguments.first else {
            Issue.record("expected a WaveformSeek, got \(rig.osc.sent)")
            return
        }
        // In all 2 + 3523 - 131 = 3394 counts: 3394 / 3600 turns × 4 s = 3.7711 s of 200 s, from 0.5 to 0.518856.
        #expect(abs(Double(before) - 0.518_856) < 0.000_01)
    }
}
