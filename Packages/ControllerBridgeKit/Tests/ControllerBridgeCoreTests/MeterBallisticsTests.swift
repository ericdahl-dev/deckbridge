@testable import ControllerBridgeCore
import Testing

/// The level meter's ballistics (#582), toward Syndicate's channel meter: the highest level sampled since the last step
/// (so a hit between sends isn't missed), an instant rise, a linear fall from full to empty in `fallTime` (0.5 s to
/// start, tuned with the owner), and a peak that holds `peakHold`, then falls at the same rate. Above 1.0 is clip.
@Suite("Meter ballistics")
struct MeterBallisticsTests {
    @Test("The rise is instant, and the highest sample since the last step counts, not the latest")
    func highestSinceLastStep() {
        var meter = MeterBallistics()
        meter.sample(0.9, at: 1.001)
        meter.sample(0.1, at: 1.005)
        meter.step(at: 1.01)
        #expect(meter.level == 0.9)
    }

    @Test("The fall is linear, full to empty in fallTime: from 1.0, half after 0.25 s, empty after 0.5 s")
    func fall() {
        #expect(MeterBallistics.fallTime == 0.5)
        var meter = MeterBallistics()
        meter.sample(1.0, at: 1)
        meter.step(at: 1)
        for step in 1...25 {
            meter.sample(0, at: 1 + Double(step) * 0.01)
            meter.step(at: 1 + Double(step) * 0.01)
        }
        #expect(abs(meter.level - 0.5) < 1e-9)
        for step in 26...50 { meter.step(at: 1 + Double(step) * 0.01) }
        #expect(meter.level < 1e-9)
    }

    @Test("A level under the falling bar doesn't pull it down faster; one above it lifts it at once")
    func fallFloor() {
        var meter = MeterBallistics()
        meter.sample(1.0, at: 1)
        meter.step(at: 1)
        meter.sample(0.2, at: 1.1)
        meter.step(at: 1.1)
        #expect(abs(meter.level - 0.8) < 1e-9)
        meter.sample(0.95, at: 1.2)
        meter.step(at: 1.2)
        #expect(meter.level == 0.95)
    }

    @Test("The peak holds peakHold (0.3 s), then falls at the fall rate instead of snapping to the level")
    func peak() {
        #expect(MeterBallistics.peakHold == 0.3)
        var meter = MeterBallistics()
        meter.sample(1.0, at: 1)
        meter.step(at: 1)
        meter.step(at: 1.3)
        #expect(meter.peak == 1.0)
        meter.step(at: 1.4)
        #expect(abs(meter.peak - 0.8) < 1e-9)
    }

    @Test("Above 1.0 is clip: shown as 1.0")
    func clip() {
        var meter = MeterBallistics()
        meter.sample(1.22, at: 1)
        meter.step(at: 1)
        #expect(meter.level == 1.0 && meter.peak == 1.0)
    }

    @Test("With a rise time it climbs at full per riseTime instead of jumping: 0.1 s rise, 0.05 s after a full hit, half")
    func riseTime() {
        #expect(MeterBallistics.riseTime == 0)
        var meter = MeterBallistics(riseTime: 0.1, fallTime: 0.5)
        meter.step(at: 1)
        meter.sample(1.0, at: 1.05)
        meter.step(at: 1.05)
        #expect(abs(meter.level - 0.5) < 1e-9)
    }
}
