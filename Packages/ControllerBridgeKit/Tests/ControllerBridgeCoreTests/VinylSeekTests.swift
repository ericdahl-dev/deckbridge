import Foundation
@testable import ControllerBridgeCore
import Testing

/// VINYL toggles what the jog does on a playing deck (#540, the owner's pick): off (the default), it bends the tempo
/// (PhaseBend), as before; on, it moves through the track (WaveformSeek), as the paused jog does, with the same step
/// and the same quantize hold, so Syndicate doesn't snap each move to the grid. Syndicate has no scratch input: this
/// seeks.
@Suite("VINYL: the playing jog bends or seeks")
struct VinylSeekTests {
    typealias Q = JogQuantizeTests

    static func vinyl(_ rig: Rig) {
        rig.coordinator.midi(.noteOn(channel: 0, note: 19, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.midi(.noteOff(channel: 0, note: 19, velocity: 0), source: Rig.lc6000.id)
    }

    /// The paused rig from JogQuantizeTests, now playing.
    static func playing() throws -> Rig {
        let rig = try Q.paused()
        ContinuousTests.feedback(rig, "Playing", [.int(1)])
        rig.osc.sent.removeAll()
        return rig
    }

    @Test("VINYL on: a playing deck's jog seeks, quantize held at None first, as the paused jog does")
    func onSeeks() throws {
        let rig = try Self.playing()
        Self.vinyl(rig)
        rig.osc.sent.removeAll()
        rig.clock.now = 10
        ContinuousTests.platterAt(rig, 2100)
        #expect(Q.addresses(rig) == ["/Syndicate/Deck/1/Quantize", "/Syndicate/Deck/1/WaveformSeek"])
        #expect(rig.osc.sent.first == Q.quantizeNone)
    }

    @Test("The same step as the paused jog: 100 counts of 1000 a turn, 4 s a turn, on 200 s from halfway is 0.502")
    func sameStep() throws {
        let rig = try Self.playing()
        Self.vinyl(rig)
        rig.osc.sent.removeAll()
        ContinuousTests.platterAt(rig, 2100)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/WaveformSeek", [.float(0.502)]))
    }

    @Test("A second VINYL press turns it off: the playing jog bends again")
    func offBends() throws {
        let rig = try Self.playing()
        Self.vinyl(rig)
        Self.vinyl(rig)
        rig.osc.sent.removeAll()
        ContinuousTests.platterAt(rig, 2100)
        #expect(Q.addresses(rig) == ["/Syndicate/Deck/1/PhaseBend"])
    }

    @Test("A paused deck's jog is the same in both modes: it seeks, quantize held")
    func pausedUnchanged() throws {
        for presses in [0, 1] {
            let rig = try Q.paused()
            for _ in 0..<presses { Self.vinyl(rig) }
            rig.osc.sent.removeAll()
            ContinuousTests.platterAt(rig, 2100)
            #expect(Q.addresses(rig) == ["/Syndicate/Deck/1/Quantize", "/Syndicate/Deck/1/WaveformSeek"])
            #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/WaveformSeek", [.float(0.502)]))
        }
    }

    @Test("Turning seek on mid-bend ends the bend")
    func onEndsBend() throws {
        let rig = try Self.playing()
        ContinuousTests.platterAt(rig, 2100)
        #expect(Q.addresses(rig) == ["/Syndicate/Deck/1/PhaseBend"])
        rig.osc.sent.removeAll()
        Self.vinyl(rig)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)])])
    }

    @Test("VINYL's light: full (127) while seek mode is on, even after release; idle (1) once it's off")
    func light() throws {
        let rig = try Rig()
        rig.coordinator.start()
        Self.vinyl(rig)
        #expect(rig.leds[19] == 127)
        Self.vinyl(rig)
        #expect(rig.leds[19] == 1)
    }

    @Test("Each layer keeps its own mode, and a layer change repaints VINYL's light for it")
    func perLayer() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: LayersTests.lc6000Layers))
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        LayersTests.note(rig, channel: 1, 19, 127)
        LayersTests.note(rig, channel: 1, 19, 0)
        output.sent.removeAll()
        LayersTests.switchLayer(rig, from: 1, to: 2)
        // Layer 2's own mode is off: idle on ch2 (channel 1 counted from 0).
        #expect(output.sent.contains(.noteOn(channel: 1, note: 19, velocity: 1)))
        #expect(!output.sent.contains(.noteOn(channel: 1, note: 19, velocity: 127)))
        output.sent.removeAll()
        // Apart from the last change by more than the layer settle (#553), so it repaints at once.
        rig.clock.now += 1
        LayersTests.switchLayer(rig, from: 2, to: 1)
        // Back on layer 1: still on.
        #expect(output.sent.contains(.noteOn(channel: 0, note: 19, velocity: 127)))
    }
}
