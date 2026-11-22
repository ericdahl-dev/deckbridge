@testable import ControllerBridgeCore
import Testing

/// The main CUE button, CDJ-style (#360), checked live with the user on the LC6000 (Quantize None):
/// - Syndicate's own `Cue` jumps back and stops while playing, and previews while held at the cue point. Both OK.
/// - Paused elsewhere, Syndicate's `Cue` makes that spot the cue point (CDJ-style). Shift + CUE goes back to the cue point
///   and stops, the user's pick: the bridge remembers where it is, from where the deck stops after a CUE, and seeks there.
/// - PLAY while CUE is held keeps playing after CUE is let go: `Playing 1`, not the `PlayPause` toggle.
/// The LC6000 rig: Play is note 1, Cue note 2, Shift note 26, all on channel 1.
@Suite("Main CUE, CDJ-style")
struct MainCueTests {
    static let cueDown = OSCMessage("/Syndicate/Deck/1/Cue", [.int(1)])
    static let cueUp = OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)])
    static let quantizeNone = OSCMessage("/Syndicate/Deck/1/Quantize", [.int(1)])
    static let quantizeGlobal = OSCMessage("/Syndicate/Deck/1/Quantize", [.int(0)])

    /// A 200-second track, loaded and stopped.
    static func started() throws -> Rig {
        let rig = try TransportTests.started()
        ShiftCuePausedTests.loadTrack(rig)
        feed(rig, "Loaded", 1)
        feed(rig, "Playing", 0)
        rig.osc.sent.removeAll()
        return rig
    }

    static func feed(_ rig: Rig, _ name: String, _ value: Int32) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/" + name, [.int(value)]))
    }

    static func position(_ rig: Rig, _ seconds: Float) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Position", [.float(seconds)]))
    }

    static func tap(_ rig: Rig, _ note: UInt8) {
        TransportTests.press(rig, note)
        TransportTests.release(rig, note)
    }

    /// The cue point learned at 30.0 s: playing from 40 s, CUE jumps back and stops, Syndicate reports where.
    static func learnAt30(_ rig: Rig) {
        feed(rig, "Playing", 1)
        position(rig, 40)
        TransportTests.press(rig, 2)
        feed(rig, "Playing", 0)
        position(rig, 30)
        TransportTests.release(rig, 2)
        rig.osc.sent.removeAll()
    }

    static func seekFraction(_ message: OSCMessage) -> Float? {
        guard message.address == "/Syndicate/Deck/1/WaveformSeek", case .float(let value)? = message.arguments.first else { return nil }
        return value
    }

    @Test("PLAY while CUE is held: Playing 1, not the PlayPause toggle, and no Cue release, which would return (the user's test of Cue 0)")
    func playLatchesPreview() throws {
        let rig = try Self.started()
        TransportTests.press(rig, 2)
        Self.feed(rig, "Playing", 1)
        TransportTests.press(rig, 1)
        TransportTests.release(rig, 1)
        TransportTests.release(rig, 2)
        #expect(rig.osc.sent == [Self.cueDown, OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)])])
        rig.coordinator.stop()
        #expect(!rig.osc.sent.contains(Self.cueUp), "quitting doesn't send it either")
    }

    @Test("After a latched preview, the next CUE is a plain hold again")
    func cueAfterLatch() throws {
        let rig = try Self.started()
        TransportTests.press(rig, 2)
        TransportTests.press(rig, 1)
        TransportTests.release(rig, 2)
        rig.osc.sent.removeAll()
        Self.tap(rig, 2)
        #expect(rig.osc.sent == [Self.cueDown, Self.cueUp])
    }

    @Test("PLAY without CUE held is still the PlayPause toggle")
    func playAlone() throws {
        let rig = try Self.started()
        Self.tap(rig, 1)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])])
    }

    /// Shift + CUE, paused away from the cue point: back to it and stopped.
    static func shiftCue(_ rig: Rig) {
        TransportTests.press(rig, 26)
        tap(rig, 2)
        TransportTests.release(rig, 26)
    }

    @Test("Shift + CUE paused away from the learned cue point: back to it, stopped, with no Cue sent, so Syndicate keeps its cue")
    func shiftCueReturns() throws {
        let rig = try Self.started()
        Self.learnAt30(rig)
        Self.position(rig, 52)                // jogged away while paused
        Self.shiftCue(rig)
        try #require(rig.osc.sent.count == 3, "\(rig.osc.sent)")
        #expect(rig.osc.sent[0] == Self.quantizeNone)
        #expect(Self.seekFraction(rig.osc.sent[1]).map { abs($0 - 0.15) < 0.00001 } == true)
        #expect(rig.osc.sent[2] == Self.quantizeGlobal)
    }

    @Test("Shift + CUE while playing is Syndicate's CUE: it jumps back and stops")
    func shiftCuePlaying() throws {
        let rig = try Self.started()
        Self.feed(rig, "Playing", 1)
        Self.position(rig, 40)
        rig.osc.sent.removeAll()
        Self.shiftCue(rig)
        #expect(rig.osc.sent == [Self.cueDown, Self.cueUp])
    }

    @Test("Shift + CUE paused with no cue point learned, or already on it: nothing, so it never sets a new cue")
    func shiftCueNothing() throws {
        let rig = try Self.started()
        Self.position(rig, 52)
        Self.shiftCue(rig)
        #expect(rig.osc.sent == [])
        Self.learnAt30(rig)
        Self.shiftCue(rig)
        #expect(rig.osc.sent == [])
    }

    @Test("Plain CUE paused away from the cue point is still Syndicate's own (it sets the cue there, CDJ-style), and the bridge learns the new spot")
    func plainCueSets() throws {
        let rig = try Self.started()
        Self.learnAt30(rig)
        Self.position(rig, 52)
        Self.tap(rig, 2)
        #expect(rig.osc.sent == [Self.cueDown, Self.cueUp])
        Self.position(rig, 70)                // jogged away again
        rig.osc.sent.removeAll()
        Self.shiftCue(rig)
        #expect(rig.osc.sent.compactMap(Self.seekFraction).map { abs($0 - 0.26) < 0.00001 } == [true])
    }

    @Test("Never learned: plain CUE is Syndicate's own, as before")
    func unlearned() throws {
        let rig = try Self.started()
        Self.position(rig, 52)
        Self.tap(rig, 2)
        #expect(rig.osc.sent == [Self.cueDown, Self.cueUp])
    }

    @Test("A new track forgets the cue point")
    func newTrackForgets() throws {
        let rig = try Self.started()
        Self.learnAt30(rig)
        ShiftCuePausedTests.loadTrack(rig, title: "other")
        Self.position(rig, 52)
        rig.osc.sent.removeAll()
        Self.shiftCue(rig)
        #expect(rig.osc.sent == [], "the old track's cue point is gone")
    }
}

/// The user's MIDI Monitor sequence (#360): CUE, PLAY, then Shift + CUE, all note 2 with the app's Shift (note 26).
@Suite("Main CUE, the user's sequence")
struct MainCueSequenceTests {
    /// CUE on the stopped deck at 0 s (it previews, then returns), then PLAY.
    static func cueThenPlay(_ rig: Rig) {
        MainCueTests.position(rig, 0)
        MainCueTests.tap(rig, 2)
        MainCueTests.feed(rig, "Playing", 1)
        MainCueTests.position(rig, 0.5)
        MainCueTests.feed(rig, "Playing", 0)
        MainCueTests.position(rig, 0)
        MainCueTests.tap(rig, 1)
        MainCueTests.feed(rig, "Playing", 1)
        MainCueTests.position(rig, 3)
    }

    @Test("Shift + CUE while playing: Syndicate's Cue, pressed and released")
    func whilePlaying() throws {
        let rig = try MainCueTests.started()
        Self.cueThenPlay(rig)
        rig.osc.sent.removeAll()
        MainCueTests.shiftCue(rig)
        #expect(rig.osc.sent == [MainCueTests.cueDown, MainCueTests.cueUp])
    }

    @Test("Paused with PLAY at 9 s: Shift + CUE seeks to 0 s, with quantize None")
    func pausedAway() throws {
        let rig = try MainCueTests.started()
        Self.cueThenPlay(rig)
        MainCueTests.position(rig, 9)
        MainCueTests.tap(rig, 1)
        MainCueTests.feed(rig, "Playing", 0)
        rig.osc.sent.removeAll()
        MainCueTests.shiftCue(rig)
        #expect(rig.osc.sent == [MainCueTests.quantizeNone, OSCMessage("/Syndicate/Deck/1/WaveformSeek", [.float(0)]),
                                 MainCueTests.quantizeGlobal])
    }
}
