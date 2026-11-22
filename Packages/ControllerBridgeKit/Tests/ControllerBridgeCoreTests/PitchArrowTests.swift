import Foundation
@testable import ControllerBridgeCore
import Testing

/// The pitch arrows (#475): while the pitch fader waits to meet Syndicate's tempo (pickup), the arrow pointing the way
/// to move it is lit. "Back" lights to move the fader toward a lower raw value, "forward" toward a higher one; which
/// physical arrow is which is the profile's (#480).
@Suite("Pitch arrows")
struct PitchArrowTests {
    @Test("Two optional LED keys name the arrows: the LC6000's are 41 (back) and 43 (forward); left out, there are none")
    func keys() throws {
        let lc6000 = try Mapping.bundledDefault()
        #expect(lc6000.leds.pitchArrowBack == 41)
        #expect(lc6000.leds.pitchArrowForward == 43)
        #expect(ProfileKeys.key("leds.pitch_arrow_back")?.range == 0...127)
        #expect(ProfileKeys.key("leds.pitch_arrow_forward")?.range == 0...127)
        var leds = lc6000.leds
        leds.pitchArrowBack = nil
        leds.pitchArrowForward = nil
        let decoded = try JSONDecoder().decode(Mapping.LEDs.self, from: JSONEncoder().encode(leds))
        #expect(decoded.pitchArrowBack == nil && decoded.pitchArrowForward == nil)
    }

    static func problems(_ leds: String) -> [String] { Mapping.problems(in: Data(#"{"leds": \#(leds)}"#.utf8)) }

    @Test("The check refuses an arrow on a note another light uses: the center light, the ring, the other arrow, a button")
    func noteAnotherLightUses() {
        #expect(Self.problems(#"{"pitch_arrow_back": 42}"#) == ["leds.pitch_arrow_back: note 42 is also leds.pitch_center"])
        #expect(Self.problems(#"{"pitch_arrow_forward": 40}"#) == ["leds.pitch_arrow_forward: note 40 is also leds.ring and notes.platter_touch"])
        #expect(Self.problems(#"{"pitch_arrow_forward": 41}"#) == ["leds.pitch_arrow_forward: note 41 is also leds.pitch_arrow_back"])
        #expect(Self.problems(#"{"pitch_arrow_back": 1}"#) == ["leds.pitch_arrow_back: note 1 is also notes.play"])
        #expect(Self.problems(#"{"pitch_arrow_back": 128}"#).count == 1)   // range-checked
        #expect(Self.problems(#"{"pitch_arrow_back": 44, "pitch_arrow_forward": 45}"#) == [])
    }

    static let back: UInt8 = 41, forward: UInt8 = 43

    /// The fader at a raw 14-bit position: the MSB, then the LSB, as the LC6000 sends them.
    static func fader(_ rig: Rig, _ raw: Int) {
        ContinuousTests.cc(rig, 8, UInt8(raw >> 7))
        ContinuousTests.cc(rig, 40, UInt8(raw & 0x7F))
    }

    /// A loaded deck whose tempo Syndicate reports as `tempo` (not the bridge's echo): pickup is pending.
    static func pending(tempo: Float = 0.5) throws -> Rig {
        let rig = try ContinuousTests.started()
        ContinuousTests.feedback(rig, "Loaded", [.int(1)])
        ContinuousTests.feedback(rig, "TempoSlider", [.float(tempo)])
        return rig
    }

    @Test("Pickup pending, the fader below Syndicate's value: forward full, back off; above it: back full, forward off")
    func arrowPointsTheWay() throws {
        let rig = try Self.pending()
        Self.fader(rig, 0x2000)   // well below +0.5
        #expect(rig.leds[Self.forward] == 127 && rig.leds[Self.back] == 0)
        #expect(rig.osc.sent.filter { $0.address.hasSuffix("TempoSlider") }.isEmpty)   // still waiting
        let other = try Self.pending(tempo: -0.5)
        Self.fader(other, 0x3000)   // above -0.5
        #expect(other.leds[Self.back] == 127 && other.leds[Self.forward] == 0)
    }

    @Test("pitch.invert: the arrows follow the raw fader, not the tempo. Low raw is a high tempo here, so it must go up: forward")
    func invertFlips() throws {
        let rig = try ContinuousTests.started(#"{"pitch": {"invert": true}}"#)
        ContinuousTests.feedback(rig, "Loaded", [.int(1)])
        ContinuousTests.feedback(rig, "TempoSlider", [.float(0.5)])
        Self.fader(rig, 0x0800)   // raw near the bottom: tempo near +1 inverted, above +0.5
        #expect(rig.leds[Self.forward] == 127 && rig.leds[Self.back] == 0)
    }

    /// The lowest raw position whose tempo is within the LC6000's pickup tolerance (0.02) of 0.5, as sent (rounded).
    static let catchEdge: Int = (0...16383).first { raw in
        abs((tempoSlider(from: raw, invert: false, deadZone: 0.005) * 100_000).rounded() / 100_000 - 0.5) <= 0.02
    }!

    @Test("The arrows go out exactly where pickup catches: one step short, still lit and waiting; at the edge, both off and the fader drives")
    func catchEdgeTurnsBothOff() throws {
        let rig = try Self.pending()
        Self.fader(rig, 0x2000)
        Self.fader(rig, Self.catchEdge - 1)
        #expect(rig.leds[Self.forward] == 127)
        #expect(rig.osc.sent.filter { $0.address.hasSuffix("TempoSlider") }.isEmpty)
        Self.fader(rig, Self.catchEdge)
        #expect(rig.leds[Self.forward] == 0 && rig.leds[Self.back] == 0)
        #expect(rig.osc.sent.contains { $0.address.hasSuffix("TempoSlider") })
    }

    @Test("Crossing the value in one jump catches too: both off in that step")
    func crossingCatches() throws {
        let rig = try Self.pending()
        Self.fader(rig, 0x2000)
        Self.fader(rig, 0x3F00)   // past +0.5 in one move
        #expect(rig.leds[Self.forward] == 0 && rig.leds[Self.back] == 0)
        #expect(rig.osc.sent.contains { $0.address.hasSuffix("TempoSlider") })
    }

    /// The LC6000 following its four layers, decks 1 and 2 loaded, Syndicate reporting deck 2's tempo at +0.5.
    static func layered() throws -> ProfileMatchingTests.ProfileRig {
        let unit = JogDisplayRingHoldTests.lc6000
        let rig = ProfileMatchingTests.ProfileRig(profiles: try ControllerProfile.bundled(), sources: [unit])
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: unit, output: MIDIEndpoint(id: unit.id + 1000, name: unit.name))],
            layers: LayersTests.lc6000Layers))
        for deck in 1...2 { rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/\(deck)/Loaded", [.int(1)])) }
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/TempoSlider", [.float(0.5)]))
        return rig
    }

    /// The last velocity sent to `note` on the LC6000's output, on any channel.
    static func lastLED(_ rig: ProfileMatchingTests.ProfileRig, _ note: UInt8) -> UInt8? {
        let out = rig.midi.outputs[JogDisplayRingHoldTests.lc6000.id + 1000]?.sent ?? []
        return out.compactMap { if case .noteOn(_, note, let velocity) = $0 { velocity } else { nil } }.last
    }

    @Test("A layer change to a deck whose tempo is above the fader: forward lights at once, from where the fader was (the unit doesn't resend it)")
    func layerChangeLightsTheWay() throws {
        let rig = try Self.layered()
        let unit = JogDisplayRingHoldTests.lc6000.id
        rig.coordinator.midi(.controlChange(channel: 0, controller: 8, value: 0x20), source: unit)   // deck 1's fader, low
        rig.coordinator.midi(.controlChange(channel: 0, controller: 40, value: 0), source: unit)
        rig.coordinator.midi(.noteOn(channel: 0, note: 51, velocity: 0), source: unit)
        rig.coordinator.midi(.noteOn(channel: 1, note: 51, velocity: 127), source: unit)   // to deck 2
        #expect(Self.lastLED(rig, Self.forward) == 127)
        #expect(Self.lastLED(rig, Self.back) == 0)
    }

    @Test("A tempo change from Syndicate (a sync) starts pickup: the arrow toward the new value lights")
    func syndicateTempoChange() throws {
        let rig = try Self.pending(tempo: 0)
        Self.fader(rig, 0x1000)   // -0.5, below 0: forward
        #expect(rig.leds[Self.forward] == 127)
        ContinuousTests.feedback(rig, "TempoSlider", [.float(-0.9)])   // synced down, below the fader
        #expect(rig.leds[Self.back] == 127 && rig.leds[Self.forward] == 0)
    }

    @Test("A pitch reset (Shift + Key Lock, #114) starts pickup at 0: the arrow toward the center lights")
    func pitchResetLights() throws {
        let rig = try ContinuousTests.started()
        ContinuousTests.feedback(rig, "Loaded", [.int(1)])
        Self.fader(rig, 0x3000)   // no report yet: the fader drives, +0.5
        rig.coordinator.midi(.noteOn(channel: 0, note: 26, velocity: 127), source: Rig.lc6000.id)   // Shift
        rig.coordinator.midi(.noteOn(channel: 0, note: 22, velocity: 127), source: Rig.lc6000.id)   // Key Lock
        #expect(rig.leds[Self.back] == 127 && rig.leds[Self.forward] == 0)
    }

    @Test("No arrow while the tempo slider is disabled (a synced follower)")
    func sliderDisabled() throws {
        let rig = try Self.pending()
        ContinuousTests.feedback(rig, "TempoSliderEnabled", [.int(0)])
        Self.fader(rig, 0x1000)
        #expect(rig.leds[Self.forward] == 0 && rig.leds[Self.back] == 0)
    }

    @Test("No arrow with no track loaded")
    func notLoaded() throws {
        let rig = try ContinuousTests.started()
        ContinuousTests.feedback(rig, "TempoSlider", [.float(0.5)])
        Self.fader(rig, 0x1000)
        #expect(rig.leds[Self.forward] == 0 && rig.leds[Self.back] == 0)
    }

    @Test("No arrow with the controller's LEDs off: nothing is sent to either")
    func ledsOff() throws {
        let rig = try Rig()
        rig.coordinator.start(ledsEnabled: false)
        ContinuousTests.feedback(rig, "Loaded", [.int(1)])
        ContinuousTests.feedback(rig, "TempoSlider", [.float(0.5)])
        Self.fader(rig, 0x1000)
        #expect(rig.leds[Self.forward] == nil && rig.leds[Self.back] == nil)
    }

    /// Every velocity sent to `note`, in order.
    static func writes(_ rig: Rig, _ note: UInt8) -> [UInt8] {
        (rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).compactMap { if case .noteOn(_, note, let v) = $0 { v } else { nil } }
    }

    @Test("Only changes go out: the fader moving further on the same side sends nothing more to either arrow")
    func onlyChanges() throws {
        let rig = try Self.pending()
        Self.fader(rig, 0x1000)
        let (back, forward) = (Self.writes(rig, Self.back).count, Self.writes(rig, Self.forward).count)
        for raw in [0x1100, 0x1200, 0x1300] { Self.fader(rig, raw) }
        #expect(Self.writes(rig, Self.back).count == back && Self.writes(rig, Self.forward).count == forward)
    }

    @Test("A captured controller holds the arrows like its other lights; given back, they show the state now")
    func captureHolds() throws {
        let rig = try Self.pending()
        Self.fader(rig, 0x1000)   // forward
        rig.coordinator.setCapture(source: Rig.lc6000.id)
        let before = (Self.writes(rig, Self.back), Self.writes(rig, Self.forward))
        ContinuousTests.feedback(rig, "TempoSlider", [.float(-0.9)])
        #expect(Self.writes(rig, Self.back) == before.0 && Self.writes(rig, Self.forward) == before.1)
        rig.coordinator.setCapture(source: nil)
        // The capture swept the fader, so its position is still the last one known: -0.5, above -0.9: back.
        #expect(rig.leds[Self.back] == 127 && rig.leds[Self.forward] == 0)
    }

    @Test("The center light behaves as today: dim while waiting, full at 0 once caught")
    func centerUnchanged() throws {
        let rig = try Self.pending(tempo: 0)
        Self.fader(rig, 0x1000)
        #expect(rig.leds[42] == 1)
        Self.fader(rig, 0x2000)   // the center: caught at 0
        #expect(rig.leds[42] == 127)
    }
}
