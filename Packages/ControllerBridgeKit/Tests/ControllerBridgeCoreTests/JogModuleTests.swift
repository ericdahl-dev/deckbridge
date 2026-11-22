import Foundation
@testable import ControllerBridgeCore
import Testing

/// The jog wheel and Needle Drop strip as one module (#383): playing, the jog bends; paused, the jog and the strip seek
/// with the deck's quantize held at None (#366) until the seeking stops. Plain values in, sends out.
@Suite("Jog module")
struct JogModuleTests {
    typealias Send = JogModule.Send
    /// 1000 counts a turn, 4 s a turn while paused, 4 beats a turn with no track length.
    static func wheel() throws -> Mapping.Jog { try #require(try Mapping.bundledDefault(overriddenBy: Data(ContinuousTests.scaled.utf8)).jog) }
    static let needle = Mapping.Needle(msbCC: 64, lsbCC: 65, touchNote: 70, requireTouch: true)

    /// The platter at `position`, 14-bit.
    static func platter(_ jog: inout JogModule, _ position: Int, wheel: Mapping.Jog, playing: Bool = false, duration: Double? = 200,
                        now: Double = 0) -> [Send] {
        jog.jogMSB(UInt8(position >> 7))
        return jog.jogLSB(UInt8(position & 0x7F), wheel: wheel, playing: playing, duration: duration, now: now)
    }

    @Test("Paused, half a turn from 0.5 of a 200 s track: quantize held, then a seek to 0.51")
    func pausedSeek() throws {
        let wheel = try Self.wheel()
        var jog = JogModule()
        jog.platterTouch(true)
        jog.progressReported(0.5)
        #expect(Self.platter(&jog, 2000, wheel: wheel) == [])
        #expect(Self.platter(&jog, 2500, wheel: wheel) == [.hold(.jogSeek), .osc("WaveformSeek", .float(0.51))])
    }

    @Test("Playing, across the wrap: 16376 → 3 is 11 forward, a bend +1; back to 16380 is a bend −1; the same way again, nothing")
    func bends() throws {
        let wheel = try Self.wheel()
        var jog = JogModule()
        jog.platterTouch(true)
        _ = Self.platter(&jog, 16376, wheel: wheel, playing: true)
        #expect(Self.platter(&jog, 3, wheel: wheel, playing: true) == [.bend(1)])
        #expect(Self.platter(&jog, 16380, wheel: wheel, playing: true) == [.bend(-1)])
        #expect(Self.platter(&jog, 16370, wheel: wheel, playing: true) == [])
    }

    @Test("A bend ends when the wheel stops for bend_release_ms, when the deck stops, or when the platter is let go")
    func bendEnds() throws {
        let wheel = try Self.wheel()
        var jog = JogModule()
        jog.platterTouch(true)
        _ = Self.platter(&jog, 100, wheel: wheel, playing: true, now: 1)
        _ = Self.platter(&jog, 110, wheel: wheel, playing: true, now: 1)
        let release = 1 + Double(wheel.bendReleaseMs) / 1000
        #expect(jog.tick(now: release - 0.001, wheel: wheel) == [])
        #expect(jog.tick(now: release, wheel: wheel) == [.endBend])
        _ = Self.platter(&jog, 120, wheel: wheel, playing: true, now: 5)
        #expect(jog.playingChanged(false) == [.endBend])
        _ = Self.platter(&jog, 130, wheel: wheel, playing: true, now: 6)
        #expect(jog.platterTouch(false) == [.endBend])
    }

    @Test("Paused with no track length: whole beats, 250 counts each, keeping the remainder")
    func beatSkips() throws {
        let wheel = try Self.wheel()
        var jog = JogModule()
        jog.platterTouch(true)
        _ = Self.platter(&jog, 1000, wheel: wheel, duration: nil)
        #expect(Self.platter(&jog, 1300, wheel: wheel, duration: nil) == [.osc("BeatSkip", .int(1))])
        #expect(Self.platter(&jog, 1500, wheel: wheel, duration: nil) == [.osc("BeatSkip", .int(1))])
        #expect(Self.platter(&jog, 1600, wheel: wheel, duration: nil) == [])
    }

    @Test("Quantize goes back 0.3 s after the last paused seek, once")
    func seekIdle() throws {
        let wheel = try Self.wheel()
        var jog = JogModule()
        jog.platterTouch(true)
        jog.progressReported(0.5)
        _ = Self.platter(&jog, 2000, wheel: wheel, now: 10)
        _ = Self.platter(&jog, 2100, wheel: wheel, now: 10)
        #expect(jog.tick(now: 10.25, wheel: wheel) == [])
        #expect(jog.tick(now: 10.3, wheel: wheel) == [.release(.jogSeek)])
        #expect(jog.tick(now: 10.4, wheel: wheel) == [])
    }

    @Test("The strip: untouched, nothing; touched and paused, a held seek; playing, a plain seek; let go, quantize back")
    func needleStrip() {
        var jog = JogModule()
        jog.needleMSB(64)
        #expect(jog.needleLSB(0, needle: Self.needle, playing: false, now: 0) == [])
        #expect(jog.needleTouch(true) == [])
        jog.needleMSB(64)
        #expect(jog.needleLSB(0, needle: Self.needle, playing: false, now: 0) == [.hold(.jogSeek), .osc("WaveformSeek", .float(Float(8192.0 / 16383)))])
        jog.needleMSB(0)
        #expect(jog.needleLSB(0, needle: Self.needle, playing: true, now: 0) == [.osc("WaveformSeek", .float(0))])
        #expect(jog.needleTouch(false) == [.release(.jogSeek)])
    }

    @Test("Releasing everything lets go of the platter (a touch-only jog then doesn't move) and forgets the bend")
    func releaseAll() throws {
        var wheel = try Self.wheel()
        wheel.requireTouch = true
        var jog = JogModule()
        jog.platterTouch(true)
        _ = Self.platter(&jog, 100, wheel: wheel, playing: true)
        #expect(Self.platter(&jog, 110, wheel: wheel, playing: true) == [.bend(1)])
        jog.releaseAll()
        #expect(Self.platter(&jog, 120, wheel: wheel, playing: true) == [])
        #expect(jog.playingChanged(false) == [], "the bend's release went out with everything else")
    }
}
