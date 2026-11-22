import ControllerBridgeCore
import Foundation
import Testing

/// The brightness of the color-message LEDs (#532): DeckBridge scales each channel of the colors it sends, after the
/// 0-255 clamp and before the cut to 7 bits. 100% is the colors as they are.
@Suite("Light brightness")
struct LightBrightnessTests {
    typealias Ring = RingColorMessageTests

    @Test("At 100% the encoder's every message is byte-identical to today's, for every channel value")
    func fullIsUnchanged() throws {
        let mapping = try Mapping.bundledDefault()
        let plain = try #require(LEDColorEncoder(mapping)), full = try #require(LEDColorEncoder(mapping, brightness: 100))
        for value in -1...256 {
            let rgb = [value, 255 - value, value / 2]
            #expect(full.message(note: mapping.leds.ring, rgb: rgb) == plain.message(note: mapping.leds.ring, rgb: rgb))
        }
    }

    @Test("At 50% the ring's deck color is halved before the 7-bit cut: 255, 140, 0 → 127, 70, 0 → 63, 35, 0")
    func halfScalesTheRing() throws {
        let rig = try Ring.exact(deck: 2)
        rig.coordinator.setLightBrightness(50)
        Ring.palette(rig, slot: 3, 255, 140, 0)
        let output = try Ring.output(rig)
        output.colors.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        #expect(try Ring.colors(rig) == [[63, 35, 0]])
    }

    @Test("Changing it repaints the ring once in the new level; the single-color buttons get nothing; the same level again sends nothing")
    func changeRepaintsOnce() throws {
        let rig = try Ring.exact(deck: 2)
        Ring.palette(rig, slot: 3, 255, 140, 0)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        let output = try Ring.output(rig)
        output.colors.removeAll()
        output.sent.removeAll()
        rig.coordinator.setLightBrightness(50)
        #expect(try Ring.colors(rig) == [[63, 35, 0]])
        #expect(!output.sent.contains { if case .noteOn = $0 { true } else { false } })
        rig.coordinator.setLightBrightness(50)
        #expect(try Ring.colors(rig).count == 1)
    }

    @Test("The app's command reaches it: apply(.setLightBrightness(50)) scales the ring")
    func command() throws {
        let rig = try Ring.exact(deck: 2)
        Ring.palette(rig, slot: 3, 255, 140, 0)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        try Ring.output(rig).colors.removeAll()
        rig.coordinator.apply(.setLightBrightness(50))
        #expect(try Ring.colors(rig) == [[63, 35, 0]])
    }

    /// The user's pick: a slider from 10% to 100% in 10% steps, with no 0 (the lights never go fully off from it).
    @Test("The slider's steps are 10% to 100% in tens; any value snaps to the nearest, kept within them")
    func steps() {
        #expect(LightBrightness.steps == [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        #expect(LightBrightness.snapped(44) == 40)
        #expect(LightBrightness.snapped(45) == 50)
        #expect(LightBrightness.snapped(0) == 10)
        #expect(LightBrightness.snapped(-20) == 10)
        #expect(LightBrightness.snapped(130) == 100)
        #expect(LightBrightness.label(70) == "70%")
    }
}
