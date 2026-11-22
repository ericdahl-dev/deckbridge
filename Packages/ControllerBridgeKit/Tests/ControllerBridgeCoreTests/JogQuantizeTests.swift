import Foundation
@testable import ControllerBridgeCore
import Testing

/// The paused jog and the needle strip seek with WaveformSeek, which Syndicate quantizes while the deck's Q is on
/// (#366, the user: "jog wheel also seems to be quantized when Q is on"). So a paused seek holds the deck's quantize at
/// None (QuantizeOverride .jogSeek) and puts it back to Use Global once the seeking stops, or on any way out. Playing,
/// the jog bends (PhaseBend), which isn't quantized, and quantize is left alone.
@Suite("Paused jog and needle seeks, unquantized")
struct JogQuantizeTests {
    static let quantizeNone = OSCMessage("/Syndicate/Deck/1/Quantize", [.int(1)])
    static let quantizeGlobal = OSCMessage("/Syndicate/Deck/1/Quantize", [.int(0)])

    /// The scaled jog (1000 counts a turn, 4 s a turn) on a 200 s track, paused halfway, platter at 2000.
    static func paused() throws -> Rig {
        let rig = try ContinuousTests.started(ContinuousTests.scaled)
        ContinuousTests.feedback(rig, "TrackInfo", [.string("t"), .string("a"), .string("8A"), .float(120), .float(200),
                                                    .int(100), .int(400), .string("track")])
        ContinuousTests.feedback(rig, "Playing", [.int(0)])
        ContinuousTests.feedback(rig, "Progress", [.float(0.5)])
        ContinuousTests.platterAt(rig, 2000)
        rig.osc.sent.removeAll()
        return rig
    }

    static func addresses(_ rig: Rig) -> [String] { rig.osc.sent.map(\.address) }

    @Test("A paused seek turns quantize off first, once; further seeks don't send it again")
    func pausedSeek() throws {
        let rig = try Self.paused()
        rig.clock.now = 10
        ContinuousTests.platterAt(rig, 2100)
        #expect(rig.osc.sent.first == Self.quantizeNone)
        #expect(Self.addresses(rig) == ["/Syndicate/Deck/1/Quantize", "/Syndicate/Deck/1/WaveformSeek"])
        rig.osc.sent.removeAll()
        ContinuousTests.platterAt(rig, 2200)
        #expect(Self.addresses(rig) == ["/Syndicate/Deck/1/WaveformSeek"])
    }

    @Test("Quantize goes back to Use Global 300 ms after the last seek, on the tick, not before")
    func idleRestores() throws {
        let rig = try Self.paused()
        rig.clock.now = 10
        ContinuousTests.platterAt(rig, 2100)
        rig.osc.sent.removeAll()
        rig.clock.now = 10.25
        rig.coordinator.tick()
        #expect(!rig.osc.sent.contains(Self.quantizeGlobal))
        rig.clock.now = 10.31
        rig.coordinator.tick()
        #expect(rig.osc.sent.filter { $0.address.hasSuffix("/Quantize") } == [Self.quantizeGlobal])
    }

    @Test("Playing, the jog bends and quantize is left alone")
    func playingBends() throws {
        let rig = try Self.paused()
        ContinuousTests.feedback(rig, "Playing", [.int(1)])
        rig.osc.sent.removeAll()
        ContinuousTests.platterAt(rig, 2100)
        #expect(Self.addresses(rig) == ["/Syndicate/Deck/1/PhaseBend"])
    }

    @Test("Shift + the needle strip on a paused deck: quantize off for the seeks, back when the strip is let go")
    func needleStrip() throws {
        let rig = try Self.paused()
        rig.coordinator.midi(.noteOn(channel: 0, note: 26, velocity: 127), source: Rig.lc6000.id)   // Shift: seek (#729)
        rig.coordinator.midi(.noteOn(channel: 0, note: 70, velocity: 127), source: Rig.lc6000.id)
        ContinuousTests.strip(rig, 64, 0)
        #expect(Self.addresses(rig) == ["/Syndicate/Deck/1/Quantize", "/Syndicate/Deck/1/WaveformSeek"])
        #expect(rig.osc.sent.first == Self.quantizeNone)
        rig.osc.sent.removeAll()
        rig.coordinator.midi(.noteOff(channel: 0, note: 70, velocity: 0), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [Self.quantizeGlobal])
    }

    @Test("Shift + the needle strip on a playing deck stays quantized (a seek in time with the grid)")
    func needlePlaying() throws {
        let rig = try Self.paused()
        ContinuousTests.feedback(rig, "Playing", [.int(1)])
        rig.coordinator.midi(.noteOn(channel: 0, note: 26, velocity: 127), source: Rig.lc6000.id)   // Shift: seek (#729)
        rig.coordinator.midi(.noteOn(channel: 0, note: 70, velocity: 127), source: Rig.lc6000.id)
        rig.osc.sent.removeAll()
        ContinuousTests.strip(rig, 64, 0)
        #expect(Self.addresses(rig) == ["/Syndicate/Deck/1/WaveformSeek"])
    }

    @Test("Play while the override is held puts quantize back before it plays")
    func playRestores() throws {
        let rig = try Self.paused()
        ContinuousTests.platterAt(rig, 2100)
        rig.osc.sent.removeAll()
        rig.coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        #expect(Self.addresses(rig).prefix(2) == ["/Syndicate/Deck/1/Quantize", "/Syndicate/Deck/1/PlayPause"])
        #expect(rig.osc.sent.first == Self.quantizeGlobal)
    }

    @Test("A new track while held puts quantize back")
    func newTrackRestores() throws {
        let rig = try Self.paused()
        ContinuousTests.platterAt(rig, 2100)
        rig.osc.sent.removeAll()
        ContinuousTests.feedback(rig, "TrackInfo", [.string("other"), .string("a"), .string("8A"), .float(120), .float(200),
                                                    .int(100), .int(400), .string("track")])
        #expect(rig.osc.sent.contains(Self.quantizeGlobal))
    }

    @Test("Unplugged while held: quantize back")
    func unplugRestores() throws {
        let rig = try Self.paused()
        ContinuousTests.platterAt(rig, 2100)
        rig.osc.sent.removeAll()
        rig.midi.sources = []
        rig.coordinator.devicesChanged()
        #expect(rig.osc.sent.contains(Self.quantizeGlobal), "\(rig.osc.sent)")
    }

    @Test("A cue jump overlapping a jog seek: one Quantize None, and the jog going idle doesn't restore it under the jump")
    func overlapsCueJump() throws {
        let rig = try Self.paused()
        rig.clock.now = 10
        ContinuousTests.platterAt(rig, 2100)                         // jog: Quantize None
        rig.osc.sent.removeAll()
        ShiftCuePausedTests.shiftPad(rig)                            // cue jump while the jog holds it
        #expect(Self.addresses(rig) == ["/Syndicate/Deck/1/Cue1"])
        rig.osc.sent.removeAll()
        rig.clock.now = 10.5
        rig.coordinator.tick()                                       // the jog's idle: the jump still holds it
        #expect(!rig.osc.sent.contains(Self.quantizeGlobal))
        ContinuousTests.feedback(rig, "Playing", [.int(1)])          // the launch: pause, and the last out restores
        #expect(rig.osc.sent.filter { $0.address.hasPrefix("/Syndicate/Deck/1/") }
            == [OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]), Self.quantizeGlobal])
    }
}
