@testable import ControllerBridgeCore
import Testing

/// The phase rule's value on the wire (#462), from a deck's PhaseOffset in beats: -8192 unknown, 0 in phase, else
/// 1/16384 beats, negative behind. The host owns the hysteresis and the wrap guard, so the chip and the renderer draw
/// each value as it is.
@Suite("Drawn display: the phase value")
struct DrawnPhaseTests {
    @Test("Unknown while the deck isn't playing or no offset has come")
    func unknown() {
        var phase = DrawnPhase()
        #expect(phase.value(offset: nil, playing: true) == -8192)
        #expect(phase.value(offset: 0.01, playing: false) == -8192)
    }

    @Test("Off phase, the offset in 1/16384 beats, rounded once, clamped to ±8191 (-8192 is unknown)",
          arguments: [(-0.04, -655), (0.01, 164), (0.0101, 165), (0.4999, 8190), (0.5, 8191), (-0.5, -8191)])
    func measured(offset: Double, wire: Int) {
        var phase = DrawnPhase()
        #expect(phase.value(offset: offset, playing: true) == wire)
    }

    /// The values in turn for a run of offsets, all while playing.
    static func run(_ offsets: [Double], from start: DrawnPhase = DrawnPhase()) -> [Int] {
        var phase = start
        return offsets.map { phase.value(offset: $0, playing: true) }
    }

    @Test("In phase is entered under 0.002 of a beat and left only over 0.004, so the tick doesn't flicker at the edge")
    func hysteresis() {
        // 0.003 is off phase coming in, in phase once in (until it passes 0.004); behind the same.
        #expect(Self.run([0.003, 0.0019, 0.003, 0.0039, 0.0041]) == [49, 0, 0, 0, 67])
        #expect(Self.run([-0.003, -0.001, -0.004, -0.0045]) == [-49, 0, 0, -74])
    }

    @Test("Stopping forgets in phase: playing again starts outside it")
    func stoppingForgets() {
        var phase = DrawnPhase()
        #expect(phase.value(offset: 0.001, playing: true) == 0)
        #expect(phase.value(offset: 0.003, playing: false) == -8192)
        #expect(phase.value(offset: 0.003, playing: true) == 49)
    }

    @Test("Wrap guard: an unsynced deck drifting through ±0.5 holds its side as a full bar until it's back under 0.4")
    func wrapSweep() {
        // Drifting ahead: 0.3 to the wrap, then Syndicate's offset jumps to -0.5 and comes back up.
        let values = Self.run([0.3, 0.45, 0.499, -0.499, -0.45, -0.41, -0.39, -0.3])
        #expect(values == [4915, 7373, 8176, 8191, 8191, 8191, -6390, -4915])
        // The other way: behind through the wrap.
        #expect(Self.run([-0.45, 0.48, 0.41, 0.39]) == [-7373, -8191, -8191, 6390])
    }

    @Test("Jitter at the wrap never flips the side")
    func wrapJitter() {
        #expect(Self.run([0.49, -0.49, 0.49, -0.49, -0.495]) == [8028, 8191, 8028, 8191, 8191])
    }

    @Test("Past 0.4 with no side yet (the first value), the offset shows as it is")
    func wrapFirst() {
        #expect(Self.run([-0.45]) == [-7373])
    }
}
