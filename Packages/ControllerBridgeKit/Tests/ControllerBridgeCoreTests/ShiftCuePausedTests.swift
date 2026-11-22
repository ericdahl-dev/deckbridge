import Foundation
@testable import ControllerBridgeCore
import Testing

/// Shift + hot cue pad on a stopped deck goes to the cue, paused (#358, #363). The deck's quantize is forced to None
/// for the jump (Quantize 1) and set back to Use Global (Quantize 0) on every way out, so it jumps at once whatever Q
/// is. Unlearned: Cue<n>, then Playing 0 the moment Syndicate reports Playing 1, learning where the cue is. Learned: a
/// WaveformSeek there, which is silent. The LC6000 rig: Shift is note 26, pad 1 is note 32, all on channel 1.
@Suite("Shift + hot cue pad on a stopped deck")
struct ShiftCuePausedTests {
    static func started(_ override: String? = nil) throws -> Rig {
        let rig = try PadChannelCoordinatorTests.started(override)
        feed(rig, "Playing", 0)
        rig.osc.sent.removeAll()
        return rig
    }

    static func feed(_ rig: Rig, _ name: String, _ value: Int32) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/" + name, [.int(value)]))
    }

    static func shift(_ rig: Rig, _ down: Bool) {
        rig.coordinator.midi(down ? .noteOn(channel: 0, note: 26, velocity: 127) : .noteOff(channel: 0, note: 26, velocity: 0),
                             source: Rig.lc6000.id)
    }

    /// Shift held, pad `note` pressed and released, Shift let go.
    static func shiftPad(_ rig: Rig, _ note: UInt8 = 32) {
        shift(rig, true)
        PadChannelCoordinatorTests.press(rig, note, channel: 1)
        shift(rig, false)
    }

    static let cue1 = OSCMessage("/Syndicate/Deck/1/Cue1", [.int(1)])
    static let pause = OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)])
    static let quantizeNone = OSCMessage("/Syndicate/Deck/1/Quantize", [.int(1)])
    static let quantizeGlobal = OSCMessage("/Syndicate/Deck/1/Quantize", [.int(0)])
    static let hotCue2 = [OSCMessage("/Syndicate/Deck/1/HotCue", [.int(2), .int(1)]),
                          OSCMessage("/Syndicate/Deck/1/HotCue", [.int(2), .int(0)])]

    /// A 200-second track.
    static func loadTrack(_ rig: Rig, title: String = "t") {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/TrackInfo", [.string(title), .string("a"), .string("8A"), .float(120),
                                                                            .float(200), .int(100), .int(400), .string("track")]))
    }

    /// Learns cue 2 at 29.96 s (first Position 30.02, less 0.06), and leaves the deck stopped.
    static func learnCue2(_ rig: Rig) {
        shiftPad(rig, 33)
        feed(rig, "Playing", 1)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Position", [.float(30.02)]))
        feed(rig, "Playing", 0)
        rig.osc.sent.removeAll()
    }

    @Test("Stopped, unlearned: Quantize None and Cue1, never HotCue; on Playing 1, one Playing 0 and Quantize back to Use Global")
    func stopped() throws {
        let rig = try Self.started()
        Self.shiftPad(rig)
        #expect(rig.osc.sent == [Self.quantizeNone, Self.cue1])
        rig.osc.sent.removeAll()
        Self.feed(rig, "Playing", 1)
        #expect(rig.osc.sent == [Self.pause, Self.quantizeGlobal])
        rig.osc.sent.removeAll()
        Self.feed(rig, "Playing", 0)
        Self.feed(rig, "Playing", 1)
        #expect(rig.osc.sent == [], "only the launch the pad started is paused")
    }

    @Test("Learned: Quantize None, a WaveformSeek to the cue's time itself (29.96 / 200), Quantize back; nothing more")
    func learnThenSeek() throws {
        let rig = try Self.started()
        Self.loadTrack(rig)
        Self.learnCue2(rig)
        Self.shiftPad(rig, 33)
        try #require(rig.osc.sent.count == 3, "\(rig.osc.sent)")
        #expect(rig.osc.sent[0] == Self.quantizeNone)
        #expect(rig.osc.sent[1].address == "/Syndicate/Deck/1/WaveformSeek")
        if case .float(let fraction)? = rig.osc.sent[1].arguments.first { #expect(abs(fraction - 0.1498) < 0.00001) } else { Issue.record("no fraction") }
        #expect(rig.osc.sent[2] == Self.quantizeGlobal)
        rig.osc.sent.removeAll()
        Self.feed(rig, "Playing", 1)
        #expect(rig.osc.sent == [], "a seek arms no pause")
    }

    @Test("Q on in Syndicate makes no difference: PlayPending before Playing 1 still gets the pause")
    func quantizeOnStillPauses() throws {
        let rig = try Self.started()
        Self.shiftPad(rig)
        rig.osc.sent.removeAll()
        Self.feed(rig, "PlayPending", 1)
        Self.feed(rig, "Playing", 1)
        #expect(rig.osc.sent == [Self.pause, Self.quantizeGlobal])
    }

    @Test("A new track forgets the cue times: its cue 2 is tapped and learned again")
    func newTrackForgets() throws {
        let rig = try Self.started()
        Self.loadTrack(rig)
        Self.learnCue2(rig)
        Self.loadTrack(rig, title: "another")
        Self.shiftPad(rig, 33)
        #expect(rig.osc.sent == [Self.quantizeNone, OSCMessage("/Syndicate/Deck/1/Cue2", [.int(1)])])
    }

    @Test("The same track's TrackInfo again (a Resend) keeps what was learned")
    func resendKeeps() throws {
        let rig = try Self.started()
        Self.loadTrack(rig)
        Self.learnCue2(rig)
        Self.loadTrack(rig)
        Self.shiftPad(rig, 33)
        #expect(rig.osc.sent.map(\.address).contains("/Syndicate/Deck/1/WaveformSeek"))
    }

    // MARK: Every way out puts quantize back (#363)

    @Test("No launch within 4 s: Quantize back to Use Global on the tick, and a later launch isn't paused")
    func timeout() throws {
        let rig = try Self.started()
        rig.clock.now = 100
        Self.shiftPad(rig)
        rig.osc.sent.removeAll()
        rig.clock.now = 103.9
        rig.coordinator.tick()
        #expect(!rig.osc.sent.contains(Self.quantizeGlobal), "still waiting at 3.9 s")
        rig.clock.now = 104.1
        rig.coordinator.tick()
        #expect(rig.osc.sent.filter { $0.address.hasSuffix("/Quantize") } == [Self.quantizeGlobal])
        rig.osc.sent.removeAll()
        Self.feed(rig, "Playing", 1)
        #expect(rig.osc.sent == [])
    }

    @Test("A second Shift + pad press before the launch drops the pause and puts quantize back: two quick taps play from the cue")
    func secondPressCancels() throws {
        let rig = try Self.started()
        Self.shiftPad(rig)
        rig.osc.sent.removeAll()
        Self.shiftPad(rig)
        #expect(rig.osc.sent == [Self.quantizeGlobal])
        rig.osc.sent.removeAll()
        Self.feed(rig, "Playing", 1)
        #expect(rig.osc.sent == [])
    }

    @Test("Play before the launch drops the pause and puts quantize back")
    func playCancels() throws {
        let rig = try Self.started()
        Self.shiftPad(rig)
        rig.osc.sent.removeAll()
        PadChannelCoordinatorTests.press(rig, 1, channel: 1)        // Play
        #expect(rig.osc.sent.contains(Self.quantizeGlobal))
        #expect(rig.osc.sent.map(\.address).contains("/Syndicate/Deck/1/PlayPause"))
        rig.osc.sent.removeAll()
        Self.feed(rig, "Playing", 1)
        #expect(rig.osc.sent == [])
    }

    @Test("A new track before the launch puts quantize back")
    func newTrackCancels() throws {
        let rig = try Self.started()
        Self.loadTrack(rig)
        Self.shiftPad(rig)
        rig.osc.sent.removeAll()
        Self.loadTrack(rig, title: "another")
        #expect(rig.osc.sent == [Self.quantizeGlobal])
    }

    @Test("The controller unplugged before the launch: quantize back")
    func unplugCancels() throws {
        let rig = try Self.started()
        Self.shiftPad(rig)
        rig.osc.sent.removeAll()
        rig.midi.sources = []
        rig.coordinator.devicesChanged()
        #expect(rig.osc.sent.contains(Self.quantizeGlobal), "\(rig.osc.sent)")
    }

    @Test("Quitting (stop) before the launch: quantize back")
    func stopCancels() throws {
        let rig = try Self.started()
        Self.shiftPad(rig)
        rig.osc.sent.removeAll()
        rig.coordinator.stop()
        #expect(rig.osc.sent.contains(Self.quantizeGlobal), "\(rig.osc.sent)")
    }

    // MARK: Where it applies (pins)

    @Test("Playing deck: Shift + pad is a normal hot cue, quantize untouched")
    func playingDeck() throws {
        let rig = try Self.started()
        Self.feed(rig, "Playing", 1)
        rig.osc.sent.removeAll()
        Self.shiftPad(rig, 33)
        #expect(rig.osc.sent == Self.hotCue2)
    }

    @Test("Roll mode: Shift + pad on a stopped deck still rolls, quantize untouched")
    func rollUnchanged() throws {
        let rig = try Self.started()
        PadChannelCoordinatorTests.press(rig, 28, channel: 1)         // mode_roll
        rig.osc.sent.removeAll()
        Self.shiftPad(rig)
        #expect(rig.osc.sent.allSatisfy { $0.address.contains("/SlipLoop/") } && !rig.osc.sent.isEmpty, "\(rig.osc.sent)")
    }

    @Test("A pad on the Shift pad channel (#324) on a stopped deck goes to the cue too")
    func shiftedChannel() throws {
        let rig = try Self.started(#"{ "pads": { "channel": 8, "shifted_channel": 9 } }"#)
        PadChannelCoordinatorTests.press(rig, 32, channel: 9)
        #expect(rig.osc.sent == [Self.quantizeNone, Self.cue1])
    }

    @Test("Per layer: deck 2's Shift pad on 11, deck 2 stopped, goes to deck 2's cue, deck 2's quantize")
    func perLayer() throws {
        let layers = [Mapping.Layer(channel: 1, deck: 1, padChannel: 8, shiftedPadChannel: 9),
                      Mapping.Layer(channel: 2, deck: 2, padChannel: 10, shiftedPadChannel: 11)]
        let rig = try PadChannelInheritanceTests.layered(#"""
            { "midi": { "layers": [ { "channel": 1, "deck": 1, "pad_channel": 8, "shifted_pad_channel": 9 },
                                    { "channel": 2, "deck": 2, "pad_channel": 10, "shifted_pad_channel": 11 } ] } }
            """#, layers: layers)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(0)]))
        rig.osc.sent.removeAll()
        PadChannelCoordinatorTests.press(rig, 32, channel: 11)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/Quantize", [.int(1)]), OSCMessage("/Syndicate/Deck/2/Cue1", [.int(1)])])
        rig.osc.sent.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/Playing", [.int(0)]), OSCMessage("/Syndicate/Deck/2/Quantize", [.int(0)])])
    }
}
