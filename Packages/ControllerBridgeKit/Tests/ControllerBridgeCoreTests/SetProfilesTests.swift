import ControllerBridgeCore
import Foundation
import Testing

/// An accepted import (#24) swaps the running profile: held controls are released first, the controller resyncs once,
/// and the new notes take effect. The deck (a setting) and the open ports stay.
@Suite("Set profiles")
struct SetProfilesTests {
    @Test("A new profile releases held Cue, resyncs once, then Play is on its new note; the deck setting is kept")
    func swapProfile() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)])) // Syndicate answered the start Resend.
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id) // hold Cue
        rig.osc.sent.removeAll()

        var mapping = try Mapping.bundledDefault()
        mapping.notes.buttons["play"] = 60
        mapping.deck.number = 4 // ignored: the deck is a setting, not part of the profile
        rig.coordinator.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: mapping)])

        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)]),
            OSCMessage("/Syndicate/Feedback/Resend", [.int(1)]),
        ])
        rig.osc.sent.removeAll()

        rig.coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        #expect(rig.osc.sent.isEmpty)
        rig.coordinator.midi(.noteOn(channel: 0, note: 60, velocity: 127), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])])
        // Same port: the LEDs still go to the controller's output.
        #expect(rig.midi.connected == [Rig.lc6000.id])
    }

    @Test("Two controllers on the same profile both switch, each on its own deck, with one Resend for both")
    func twoControllers() throws {
        let rig = try Rig()
        let unitB = MIDIEndpoint(id: 1005, name: "DENON LC6000 PRIME")
        rig.midi.sources.append(unitB)
        rig.coordinator.start()
        rig.coordinator.setControllers([
            ControllerSettings(deck: 1, input: nil, output: nil),
            ControllerSettings(deck: 2, input: nil, output: nil),
        ])
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)])) // answers the pending Resend
        rig.osc.sent.removeAll()

        var mapping = try Mapping.bundledDefault()
        mapping.notes.buttons["play"] = 60
        rig.coordinator.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: mapping)])
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Feedback/Resend", [.int(1)])])
        rig.osc.sent.removeAll()

        rig.coordinator.midi(.noteOn(channel: 0, note: 60, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.midi(.noteOn(channel: 0, note: 60, velocity: 127), source: unitB.id)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)]),
            OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)]),
        ])
    }

    static func newPlay(_ note: Int = 60) throws -> [ControllerProfile] {
        var mapping = try Mapping.bundledDefault()
        mapping.notes.buttons["play"] = note
        return [ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: mapping)]
    }

    @Test("Two controllers on one device keep their channels through a profile swap (#94)")
    func channelsSurvive() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setControllers([
            ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out, channel: 1),
            ControllerSettings(deck: 2, input: Rig.lc6000, output: Rig.lc6000Out, channel: 2),
        ])
        rig.coordinator.setProfiles(try Self.newPlay())
        rig.osc.sent.removeAll()
        // Channel 2 first: if both had fallen back to channel 1, one press would reach both decks in the other order.
        rig.coordinator.midi(.noteOn(channel: 1, note: 60, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.midi(.noteOn(channel: 0, note: 60, velocity: 127), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)]),
        ])
    }

    @Test("LEDs off stays off through a profile swap: the swap sends no LED message (#94)")
    func ledsOffSurvives() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setLEDs(enabled: false)
        let before = rig.midi.outputs[Rig.lc6000Out.id]?.sent.count
        rig.coordinator.setProfiles(try Self.newPlay())
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        #expect(rig.midi.outputs[Rig.lc6000Out.id]?.sent.count == before)
    }

    @Test("A profile swap keeps Syndicate's deck state: the repaint right after it already shows Play lit, with one Resend (#115)")
    func swapRepaints() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        rig.osc.sent.removeAll()
        var mapping = try Mapping.bundledDefault()
        mapping.notes.buttons["play"] = 60          // the Play LED moves to note 60
        rig.coordinator.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: mapping)])
        #expect(rig.leds[60] == 127)                // no idle blink while the Resend is answered
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Feedback/Resend", [.int(1)])])
    }

    @Test("A controller unplugged during a swap picks the new profile up when it comes back (#94)")
    func reconnectGetsNewProfile() throws {
        let rig = try Rig()
        rig.coordinator.start()
        RecoveryTests.unplug(rig)
        rig.coordinator.setProfiles(try Self.newPlay())
        RecoveryTests.replug(rig)
        rig.osc.sent.removeAll()
        rig.coordinator.midi(.noteOn(channel: 0, note: 60, velocity: 127), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])])
    }

    @Test("Cues carry over a swap: the hot-cue pads keep their colors (#115)")
    func cuesCarry() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(PadsTests.cues([1, 2, 0, 0, 0, 0, 0, 0]))
        rig.coordinator.setProfiles(try Self.newPlay())
        #expect(PadsTests.padLEDs(rig) == [48, 56, 0, 0, 0, 0, 0, 0])
    }

    @Test("The track's length and position carry over a swap: a paused jog right after it seeks, not BeatSkip (#115)")
    func trackCarries() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/TrackInfo", [.string("t"), .string("a"), .string("8A"), .float(120), .float(200), .int(100), .int(400), .string("track")]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Progress", [.float(0.5)]))
        rig.coordinator.setProfiles(try Self.newPlay())
        rig.osc.sent.removeAll()
        ContinuousTests.platterAt(rig, 1000)
        ContinuousTests.platterAt(rig, 1900)
        #expect(rig.osc.sent.last?.address == "/Syndicate/Deck/1/WaveformSeek")
    }

    @Test("Syndicate's reported tempo carries over a swap: the fader still waits to meet it instead of jumping (#115)")
    func pickupCarries() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/TempoSlider", [.float(0.5)]))
        rig.coordinator.setProfiles(try Self.newPlay())
        rig.osc.sent.removeAll()
        rig.coordinator.midi(.controlChange(channel: 0, controller: 8, value: 0x00), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [])
    }

    @Test("The bridge's own state carries over a swap: Key Lock and Roll mode stay lit, and Key Lock toggles off next (#115)")
    func ownStateCarries() throws {
        let rig = try Rig()
        rig.coordinator.start()
        for note: UInt8 in [22, 28] {   // Key Lock, Roll mode (the LC6000 has no Slip since #420)
            rig.coordinator.midi(.noteOn(channel: 0, note: note, velocity: 127), source: Rig.lc6000.id)
            rig.coordinator.midi(.noteOff(channel: 0, note: note, velocity: 0), source: Rig.lc6000.id)
        }
        rig.coordinator.setProfiles(try Self.newPlay())
        #expect(rig.leds[22] == 127)
        #expect(PadsTests.modeLEDs(rig) == [1, 127, 1, 1])
        rig.osc.sent.removeAll()
        rig.coordinator.midi(.noteOn(channel: 0, note: 22, velocity: 127), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PitchPreserve", [.int(0)])])
    }
}
