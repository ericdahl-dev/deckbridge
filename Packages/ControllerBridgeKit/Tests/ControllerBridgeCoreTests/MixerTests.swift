import ControllerBridgeCore
import Foundation
import Testing

/// The mixer section (#207): channel faders, trim, EQ, filter, cue/mute/solo and VU meters, for controllers that have
/// one. Optional: the LC6000 has none.
@Suite("Mixer")
struct MixerTests {
    static let section = #"""
        { "mixer": {
            "volume": { "msb_cc": 19, "bits": 7 },
            "trim": { "msb_cc": 4, "bits": 7 },
            "eq_high": { "msb_cc": 7, "lsb_cc": 39 },
            "eq_mid": { "msb_cc": 11, "bits": 7 },
            "eq_low": { "msb_cc": 15, "bits": 7 },
            "filter": { "msb_cc": 23, "bits": 7 },
            "cue_note": 84, "mute_note": 85, "solo_note": 86,
            "meter": { "cc": 2, "steps": [0, 16, 32, 48, 64, 80, 96, 112], "clip": 127, "hold_ms": 300, "rate_hz": 30 },
            "pickup": true, "pickup_tolerance": 0.03
        } }
        """#

    @Test("The LC6000 has no mixer, and loads as before")
    func lc6000HasNone() throws {
        #expect(try Mapping.bundledDefault().mixer == nil)
    }

    @Test("A mixer section reads its controls: 7-bit as one CC, 14-bit as a pair; unset ones are nil")
    func decodes() throws {
        let mixer = try #require(try Mapping.bundledDefault(overriddenBy: Data(Self.section.utf8)).mixer)
        #expect(mixer.volume == Mapping.Control(bits: 7, msbCC: 19, lsbCC: nil))
        #expect(mixer.eqHigh == Mapping.Control(bits: 14, msbCC: 7, lsbCC: 39))
        #expect(mixer.filterRes == nil)
        #expect(mixer.cueNote == 84)
        #expect(mixer.muteNote == 85)
        #expect(mixer.meter == Mapping.Mixer.Meter(cc: 2, steps: [0, 16, 32, 48, 64, 80, 96, 112], clip: 127, holdMs: 300, rateHz: 30))
        #expect(mixer.pickup)
        #expect(mixer.pickupTolerance == 0.03)
    }

    @Test("Meter's hold, rate and clip, and pickup, have defaults")
    func defaults() throws {
        let json = #"{ "mixer": { "meter": { "cc": 2, "steps": [0, 64, 127] } } }"#
        let mixer = try #require(try Mapping.bundledDefault(overriddenBy: Data(json.utf8)).mixer)
        #expect(mixer.meter == Mapping.Mixer.Meter(cc: 2, steps: [0, 64, 127], clip: nil, holdMs: 300, rateHz: 30))
        #expect(mixer.pickup)
        #expect(mixer.pickupTolerance == 0.02)
    }

    @Test("A 14-bit control needs its LSB, as the pitch fader does")
    func fourteenBitNeedsLSB() {
        #expect(throws: MappingError.invalid(["mixer.volume: lsb_cc is missing (or set bits to 7)"])) {
            try Mapping.bundledDefault(overriddenBy: Data(#"{ "mixer": { "volume": { "msb_cc": 19 } } }"#.utf8))
        }
    }

    // MARK: Faders and knobs (#207), at the Coordinator seam: the LC6000 plus a DDJ-400-like mixer, test-only

    static func started() throws -> Rig {
        let rig = try Rig(override: section)
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        return rig
    }

    static func cc(_ rig: Rig, _ controller: UInt8, _ value: UInt8) {
        rig.coordinator.midi(.controlChange(channel: 0, controller: controller, value: value), source: Rig.lc6000.id)
    }

    static func mixer(_ path: String, _ value: Float, channel: Int = 1) -> OSCMessage {
        OSCMessage("/Syndicate/Mixer/" + (path.hasPrefix("filter") ? path.replacingOccurrences(of: "N", with: "\(channel)") : "CH\(channel)/" + path),
                   [.float(value)])
    }

    @Test("A 7-bit fader sends 0..1, with 64 exactly 0.5 (the split rule of the 7-bit pitch fader)")
    func sevenBit() throws {
        let rig = try Self.started()
        for value: UInt8 in [0, 1, 64, 126, 127] { Self.cc(rig, 19, value) }
        #expect(rig.osc.sent == [
            Self.mixer("Volume", 0), Self.mixer("Volume", 0.00781), Self.mixer("Volume", 0.5),
            Self.mixer("Volume", 0.99206), Self.mixer("Volume", 1),
        ])
    }

    @Test("A 14-bit knob sends when its LSB arrives, 8192 exactly 0.5; trim, EQ and filter each to their own address")
    func fourteenBitAndAddresses() throws {
        let rig = try Self.started()
        Self.cc(rig, 7, 64); Self.cc(rig, 39, 0)
        Self.cc(rig, 7, 127); Self.cc(rig, 39, 127)
        Self.cc(rig, 4, 64); Self.cc(rig, 11, 64); Self.cc(rig, 15, 0); Self.cc(rig, 23, 127)
        #expect(rig.osc.sent == [
            Self.mixer("EQ/High", 0.5), Self.mixer("EQ/High", 1),
            Self.mixer("Trim", 0.5), Self.mixer("EQ/Mid", 0.5), Self.mixer("EQ/Low", 0), Self.mixer("filterN.cut", 1),
        ])
    }

    @Test("The mixer channel is the deck the controller drives: on deck 2, the fader moves channel 2")
    func channelFollowsDeck() throws {
        let rig = try Self.started()
        rig.coordinator.setDeck(2, controller: 0)
        rig.clock.now += 3   // past the wait for channel 2's values (#321), with none reported
        rig.osc.sent.removeAll()
        Self.cc(rig, 19, 127)
        #expect(rig.osc.sent.last == Self.mixer("Volume", 1, channel: 2))
    }

    @Test("The LC6000, with no mixer section, sends nothing for those CCs")
    func lc6000Unchanged() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        for controller: UInt8 in [19, 4, 7, 39, 11, 15, 23] { Self.cc(rig, controller, 100) }
        #expect(rig.osc.sent == [])
    }

    // MARK: Pickup (#207), as the pitch fader's

    static func report(_ rig: Rig, _ path: String, _ value: Float) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH1/" + path, [.float(value)]))
    }

    @Test("After Syndicate reports a volume the fader didn't send, the fader waits until it comes within tolerance")
    func picksUpWithinTolerance() throws {
        let rig = try Self.started()
        Self.report(rig, "Volume", 0.8)
        Self.cc(rig, 19, 26)   // 0.203
        Self.cc(rig, 19, 90)   // 0.706
        #expect(rig.osc.sent == [])
        Self.cc(rig, 19, 101)  // 0.79365: within 0.03
        Self.cc(rig, 19, 110)
        #expect(rig.osc.sent == [Self.mixer("Volume", 0.79365), Self.mixer("Volume", 0.86508)])
    }

    @Test("A move that jumps across the reported value picks up")
    func picksUpCrossing() throws {
        let rig = try Self.started()
        Self.report(rig, "EQ/Low", 0.5)
        Self.cc(rig, 15, 20)
        Self.cc(rig, 15, 100)
        #expect(rig.osc.sent == [Self.mixer("EQ/Low", 0.78571)])
    }

    @Test("Syndicate's echo of what the knob sent doesn't re-arm it")
    func echoKeepsItLive() throws {
        let rig = try Self.started()
        Self.cc(rig, 11, 40)
        Self.report(rig, "EQ/Mid", 0.3125)
        Self.cc(rig, 11, 41)
        #expect(rig.osc.sent == [Self.mixer("EQ/Mid", 0.3125), Self.mixer("EQ/Mid", 0.32031)])
    }

    @Test("Another channel's report doesn't arm this deck's fader; pickup false drives at once")
    func otherChannelAndOff() throws {
        let rig = try Self.started()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH2/Volume", [.float(0.9)]))
        Self.cc(rig, 19, 0)
        #expect(rig.osc.sent == [Self.mixer("Volume", 0)])

        let off = try Rig(override: Self.section.replacingOccurrences(of: #""pickup": true"#, with: #""pickup": false"#))
        off.coordinator.start()
        off.osc.sent.removeAll()
        Self.report(off, "Volume", 0.9)
        Self.cc(off, 19, 0)
        #expect(off.osc.sent == [Self.mixer("Volume", 0)])
    }

    // MARK: Cue, mute and solo (#207)

    static func press(_ rig: Rig, _ note: UInt8) {
        rig.coordinator.midi(.noteOn(channel: 0, note: note, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.midi(.noteOff(channel: 0, note: note, velocity: 0), source: Rig.lc6000.id)
    }

    @Test("A press sends the opposite of what Syndicate last reported; its LED follows Syndicate, not the press")
    func cueToggles() throws {
        let rig = try Self.started()
        Self.press(rig, 84)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Mixer/CH1/Cue", [.int(1)])])
        #expect(rig.leds[84] != 127)
        Self.report(rig, "Cue", 1)
        #expect(rig.leds[84] == 127)
        Self.press(rig, 84)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Mixer/CH1/Cue", [.int(0)]))
        Self.report(rig, "Cue", 0)
        #expect(rig.leds[84] == 1)  // the profile's dim, as an unlit button
    }

    @Test("Mute and solo work the same, each on its own address and LED")
    func muteAndSolo() throws {
        let rig = try Self.started()
        Self.report(rig, "Mute", 1)
        Self.press(rig, 85)
        Self.press(rig, 86)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Mixer/CH1/Mute", [.int(0)]), OSCMessage("/Syndicate/Mixer/CH1/Solo", [.int(1)]),
        ])
        #expect(rig.leds[85] == 127)
        #expect(rig.leds[86] == 1)
    }

    @Test("Replugged, the buttons' LEDs are repainted from what Syndicate reported meanwhile")
    func repaint() throws {
        let rig = try Self.started()
        rig.midi.sources = [MIDIEndpoint(id: 1000, name: "IAC Bus 1")]
        rig.midi.destinations = []
        rig.coordinator.devicesChanged()
        Self.report(rig, "Solo", 1)
        rig.midi.sources = [MIDIEndpoint(id: 1000, name: "IAC Bus 1"), Rig.lc6000]
        rig.midi.destinations = [Rig.lc6000Out]
        rig.coordinator.devicesChanged()
        #expect(rig.leds[86] == 127)
    }

    // MARK: VU meters (#207): steps [0, 16, 32, 48, 64, 80, 96, 112], clip 127, hold 300 ms, at most 30 Hz

    /// The meter CC values sent to the controller, in order.
    static func meterSends(_ rig: Rig) -> [UInt8] {
        (rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).compactMap {
            if case .controlChange(0, 2, let value) = $0 { value } else { nil }
        }
    }

    static func meter(_ rig: Rig, _ value: Float, at time: Double) {
        rig.clock.now = time
        Self.report(rig, "Meter", value)
    }

    static func tick(_ rig: Rig, at time: Double) {
        rig.clock.now = time
        rig.coordinator.tick()
    }

    @Test("Meter lights the steps for its level on the next tick, and above 1.0 the clip value")
    func levels() throws {
        let rig = try Self.started()
        Self.meter(rig, 0.5, at: 10.0); Self.tick(rig, at: 10.01)
        Self.meter(rig, 1.0, at: 10.10); Self.tick(rig, at: 10.11)
        Self.meter(rig, 1.2, at: 10.20); Self.tick(rig, at: 10.21)
        #expect(Self.meterSends(rig) == [48, 112, 127])
    }

    @Test("A peak holds for hold_ms, then the meter falls to the level now")
    func peakHold() throws {
        let rig = try Self.started()
        Self.meter(rig, 0.9, at: 10.00); Self.tick(rig, at: 10.01)
        Self.meter(rig, 0.1, at: 10.05); Self.tick(rig, at: 10.10)
        Self.tick(rig, at: 10.25)
        Self.tick(rig, at: 10.40)
        #expect(Self.meterSends(rig) == [96, 0])
    }

    @Test("Syndicate's ~200 Hz meter reaches the controller at 30 Hz at most (#320: a level that changes every message)")
    func rateLimited() throws {
        // 128 steps, so nearly every rising level is a new value; ticks every 5 ms for one second.
        let rig = try Rig(override: Self.section.replacingOccurrences(
            of: #""steps": [0, 16, 32, 48, 64, 80, 96, 112]"#, with: #""steps": [\#((0...127).map(String.init).joined(separator: ", "))]"#
        ))
        rig.coordinator.start()
        for i in 0...200 {
            let t = 10.0 + Double(i) * 0.005
            Self.meter(rig, Float(Double(i) / 200), at: t)
            Self.tick(rig, at: t)
        }
        // At 30 Hz over one second: at 10.000, then every 1/30 s, 31 sends at most; without the cap it would be ~128.
        let sends = Self.meterSends(rig).count
        #expect(sends >= 29)
        #expect(sends <= 31)
    }

    @Test("LEDs turned off: the meter goes dark too, and stays dark (#320)")
    func ledsOffDarkensMeter() throws {
        let rig = try Self.started()
        Self.meter(rig, 0.9, at: 10.0); Self.tick(rig, at: 10.01)
        rig.coordinator.setLEDs(enabled: false)
        #expect(Self.meterSends(rig) == [96, 0])
        Self.meter(rig, 0.5, at: 11.0); Self.tick(rig, at: 11.01)
        #expect(Self.meterSends(rig) == [96, 0])
    }

    @Test("Replugged, a steady meter level is sent again (#320)")
    func replugResendsMeter() throws {
        let rig = try Self.started()
        Self.meter(rig, 0.5, at: 10.0); Self.tick(rig, at: 10.01)
        rig.midi.sources = [MIDIEndpoint(id: 1000, name: "IAC Bus 1")]
        rig.midi.destinations = []
        rig.coordinator.devicesChanged()
        rig.midi.sources = [MIDIEndpoint(id: 1000, name: "IAC Bus 1"), Rig.lc6000]
        rig.midi.destinations = [Rig.lc6000Out]
        rig.coordinator.devicesChanged()
        Self.meter(rig, 0.5, at: 10.5); Self.tick(rig, at: 10.6)
        #expect(Self.meterSends(rig) == [48])   // the new output's first meter write
    }

    @Test("Another channel's meter, and a profile with no meter, light nothing")
    func noMeter() throws {
        let rig = try Self.started()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH2/Meter", [.float(0.8)]))
        Self.tick(rig, at: 10)
        #expect(Self.meterSends(rig) == [])
        let lc6000 = try Rig()
        lc6000.coordinator.start()
        Self.meter(lc6000, 0.8, at: 10); Self.tick(lc6000, at: 10.1)
        #expect(Self.meterSends(lc6000) == [])
    }

    // MARK: Resets (#321): a capture, a replug and a deck switch

    @Test("After a capture swept the fader, it waits to meet Syndicate's volume again instead of jumping it")
    func captureRearms() throws {
        let rig = try Self.started()
        Self.report(rig, "Volume", 0.5)
        Self.cc(rig, 19, 64)                          // picked up at 0.5
        rig.coordinator.setCapture(source: Rig.lc6000.id)
        Self.cc(rig, 19, 127)                         // swept while capturing: drives nothing
        rig.coordinator.setCapture(source: nil)
        rig.osc.sent.removeAll()
        Self.cc(rig, 19, 126)
        #expect(rig.osc.sent == [])
    }

    @Test("After a replug, the fader waits to meet Syndicate's volume again")
    func replugRearms() throws {
        let rig = try Self.started()
        Self.report(rig, "Volume", 0.5)
        Self.cc(rig, 19, 64)
        rig.midi.sources = [MIDIEndpoint(id: 1000, name: "IAC Bus 1")]
        rig.midi.destinations = []
        rig.coordinator.devicesChanged()
        rig.midi.sources = [MIDIEndpoint(id: 1000, name: "IAC Bus 1"), Rig.lc6000]
        rig.midi.destinations = [Rig.lc6000Out]
        rig.coordinator.devicesChanged()
        rig.osc.sent.removeAll()
        Self.cc(rig, 19, 126)
        #expect(!rig.osc.sent.contains { $0.address.hasSuffix("/Volume") })
    }

    @Test("On deck 2, channel 1's cue state is forgotten: its LED goes idle and a press asks channel 2 to turn cue on")
    func deckSwitchForgetsChannel() throws {
        let rig = try Self.started()
        Self.report(rig, "Cue", 1)
        #expect(rig.leds[84] == 127)
        rig.coordinator.setDeck(2, controller: 0)
        #expect(rig.leds[84] == 1)
        rig.osc.sent.removeAll()
        Self.press(rig, 84)
        #expect(rig.osc.sent.contains(OSCMessage("/Syndicate/Mixer/CH2/Cue", [.int(1)])))
    }

    @Test("Just after a deck switch, the fader waits for the new channel's volume; once it's reported, it picks up there")
    func deckSwitchWaitsForTheNewChannel() throws {
        let rig = try Self.started()
        rig.coordinator.setDeck(2, controller: 0)
        rig.osc.sent.removeAll()
        Self.cc(rig, 19, 127)
        #expect(!rig.osc.sent.contains { $0.address.hasSuffix("/Volume") })
        rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH2/Volume", [.float(1)]))
        Self.cc(rig, 19, 126)
        #expect(rig.osc.sent.last == Self.mixer("Volume", 0.99206, channel: 2))
    }
}
