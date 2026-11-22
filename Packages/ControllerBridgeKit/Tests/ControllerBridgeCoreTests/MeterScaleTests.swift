@testable import ControllerBridgeCore
import Testing

/// The level meter's scale (#582). Syndicate's raw channel level goes above 1.0 (+2.6 dB seen) while its own meter stays
/// out of the red, "near the top" on a loud passage. So the drawn meter is in decibels, from `floorDB` (empty) to
/// `topDB` (full, the red at clip): −36 to +16 dB, lowered to the owner's eye against Syndicate's meter (a passage that
/// read ~80% at +6, about −2.4 dB, now reads 65%). Expected values worked out by hand: (20·log10(v) + 36) / 52.
@Suite("Meter scale")
struct MeterScaleTests {
    @Test("−36 dB to +16 dB: the range's two named constants")
    func range() {
        #expect(MeterScale.floorDB == -36)
        #expect(MeterScale.topDB == 16)
    }

    @Test("Where levels land, on 0-127: 0 dB 88, +2.6 dB (the loudest seen) 94, −6.9 dB (the median) 71, −20 dB 39, −2.4 dB 82 (65%)")
    func positions() {
        func shown(_ value: Double) -> Int { Int((MeterScale.position(value) * 127).rounded()) }
        #expect(shown(1.0) == 88)
        #expect(shown(1.349) == 94)
        #expect(shown(0.451) == 71)
        #expect(shown(0.1) == 39)
        #expect(shown(0.5) == 73)
        #expect(shown(0.759) == 82)
    }

    @Test("Full (the red) only from +16 dB; silence, −36 dB and below, empty")
    func ends() {
        #expect(MeterScale.position(6.31) == 1)
        #expect(MeterScale.position(8) == 1)
        #expect(MeterScale.position(6.0) < 1)
        #expect(MeterScale.position(0.0158) == 0)
        #expect(MeterScale.position(0) == 0)
        #expect(MeterScale.position(-1) == 0)
    }
}
