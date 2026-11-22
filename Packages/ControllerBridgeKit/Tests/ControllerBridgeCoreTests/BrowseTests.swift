import Foundation
import ControllerBridgeCore
import Testing

/// Browse, loop and jump controls (#16). Expected OSC is from the Python bridge (lc6000_bridge/bridge.py (removed in #30)), note and
/// CC numbers are from the default mapping (Play 1 … Param ▶ 69, select turn CC 6, auto loop size CC 3).
@Suite("Browse, loops and jumps")
struct BrowseTests {
    /// A started rig with the start-up Resend cleared, so only what the test does is left.
    static func startedRig() throws -> Rig {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        return rig
    }

    static func press(_ rig: Rig, _ note: UInt8) {
        rig.coordinator.midi(.noteOn(channel: 0, note: note, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.midi(.noteOff(channel: 0, note: note, velocity: 0), source: Rig.lc6000.id)
    }

    @Test("Track ◀ and ▶ move the browser up and down, on press only")
    func trackButtons() throws {
        let rig = try Self.startedRig()
        Self.press(rig, 5)
        Self.press(rig, 6)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Browser/Up", [.int(1)]),
            OSCMessage("/Syndicate/Browser/Down", [.int(1)]),
        ])
    }

    @Test("Back goes back in the browser and Forward enters, on press only")
    func backAndForward() throws {
        let rig = try Self.startedRig()
        Self.press(rig, 16)
        Self.press(rig, 17)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Browser/Back", [.int(1)]),
            OSCMessage("/Syndicate/Browser/Enter", [.int(1)]),
        ])
    }

    @Test("Select press loads the browser's track onto this deck, on press only")
    func selectPressLoads() throws {
        let rig = try Self.startedRig()
        Self.press(rig, 18)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Browser/L1", [.int(1)])])
    }

    @Test("Select press loads onto the mapping's deck")
    func selectPressUsesDeck() throws {
        let mapping = try Mapping.bundledDefault(overriddenBy: Data(#"{ "deck": { "number": 3 } }"#.utf8))
        let osc = Rig.FakeOSC()
        let coordinator = Coordinator(
            mapping: mapping,
            midi: Rig.FakeMIDISystem(sources: [Rig.lc6000], destinations: [Rig.lc6000Out]),
            osc: osc, clock: Rig.FakeClock(), log: Rig.FakeLog()
        )
        coordinator.start()
        osc.sent.removeAll()
        coordinator.midi(.noteOn(channel: 0, note: 18, velocity: 127), source: Rig.lc6000.id)
        #expect(osc.sent == [OSCMessage("/Syndicate/Browser/L3", [.int(1)])])
    }

    static func turn(_ rig: Rig, cc: UInt8, _ value: UInt8) {
        rig.coordinator.midi(.controlChange(channel: 0, controller: cc, value: value), source: Rig.lc6000.id)
    }

    // Relative CC values per the LC6000 PRIME MIDI spec: 0x01-0x3F forward that many ticks, 0x7F-0x40 back
    // (0x7F is one tick back), 0 is no movement.
    @Test("Turning Select moves the browser one step per tick: 0x02 is two down, 0x7F one up, 0 nothing")
    func selectTurn() throws {
        let rig = try Self.startedRig()
        Self.turn(rig, cc: 6, 0x02)
        Self.turn(rig, cc: 6, 0x7F)
        Self.turn(rig, cc: 6, 0x00)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Browser/Down", [.int(1)]),
            OSCMessage("/Syndicate/Browser/Down", [.int(1)]),
            OSCMessage("/Syndicate/Browser/Up", [.int(1)]),
        ])
    }

    @Test("A fast backward turn (0x7D, three ticks) moves the browser up three")
    func selectTurnFastBack() throws {
        let rig = try Self.startedRig()
        Self.turn(rig, cc: 6, 0x7D)
        #expect(rig.osc.sent == Array(repeating: OSCMessage("/Syndicate/Browser/Up", [.int(1)]), count: 3))
    }

    @Test("Loop In, Loop Out and Auto Loop send LoopIn, LoopOut and Loop to the deck, on press only")
    func loopButtons() throws {
        let rig = try Self.startedRig()
        Self.press(rig, 8)
        Self.press(rig, 9)
        Self.press(rig, 10)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/LoopIn", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/LoopOut", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/Loop", [.int(1)]),
        ])
    }

    @Test("Turning the auto loop knob doubles the loop forward (LoopOut) and halves it back (LoopIn), once per turn")
    func autoLoopSizeKnob() throws {
        let rig = try Self.startedRig()
        Self.turn(rig, cc: 3, 0x03)
        Self.turn(rig, cc: 3, 0x7E)
        Self.turn(rig, cc: 3, 0x00)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/LoopOut", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/LoopIn", [.int(1)]),
        ])
    }

    /// A loop from `start` to `end` seconds on deck 1, as Syndicate reports it, at `bpm`.
    static func loop(_ rig: Rig, bpm: Float, start: Float, end: Float) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/BPM", [.float(bpm)]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/LoopInfo", [.int(1), .float(start), .float(end)]))
        rig.osc.sent.removeAll()
    }

    static func loopMoves(_ rig: Rig) -> [OSCMessage] {
        rig.osc.sent.filter { $0.address.contains("Loop") || $0.address.contains("Skip") }
    }

    @Test("Shift + the auto loop knob is Loop Move (#470): each click moves the loop by its own length, forward clockwise; no resize")
    func loopMove() throws {
        let rig = try Self.startedRig()
        // Hardware trace: 0.0561 s to 1.9311 s at 128 BPM is a 4-beat loop.
        Self.loop(rig, bpm: 128, start: 0.0561, end: 1.9311)
        Self.holdingShift(rig) {
            Self.turn(rig, cc: 3, 0x01)   // one click clockwise
            Self.turn(rig, cc: 3, 0x7F)   // one click counter-clockwise
            Self.turn(rig, cc: 3, 0x00)
        }
        #expect(Self.loopMoves(rig) == [
            OSCMessage("/Syndicate/Deck/1/LoopMoveBeat", [.int(4)]),
            OSCMessage("/Syndicate/Deck/1/LoopMoveBeat", [.int(-4)]),
        ])
    }

    @Test("Loop Move follows the loop's length: an 8-beat loop moves 8 beats; a loop under a beat moves 1")
    func loopMoveFollowsLength() throws {
        let rig = try Self.startedRig()
        // Hardware trace: 104.3204 s to 108.0127 s at 130 BPM is an 8-beat loop.
        Self.loop(rig, bpm: 130, start: 104.3204, end: 108.0127)
        Self.holdingShift(rig) { Self.turn(rig, cc: 3, 0x01) }
        #expect(Self.loopMoves(rig) == [OSCMessage("/Syndicate/Deck/1/LoopMoveBeat", [.int(8)])])
        Self.loop(rig, bpm: 120, start: 10, end: 10.25)   // half a beat
        Self.holdingShift(rig) { Self.turn(rig, cc: 3, 0x01) }
        #expect(Self.loopMoves(rig) == [OSCMessage("/Syndicate/Deck/1/LoopMoveBeat", [.int(1)])])
    }

    @Test("With no loop reported, Shift + the auto loop knob sends nothing")
    func loopMoveWithoutLoop() throws {
        let rig = try Self.startedRig()
        Self.holdingShift(rig) { Self.turn(rig, cc: 3, 0x01) }
        #expect(Self.loopMoves(rig) == [])
    }

    @Test("Beat jump ◀ and ▶ skip a beat back and forward, on press only")
    func beatJump() throws {
        let rig = try Self.startedRig()
        Self.press(rig, 3)
        Self.press(rig, 4)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/SkipBeatBack", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/SkipBeatForward", [.int(1)]),
        ])
    }

    @Test("Param ◀ and ▶ send BeatSkip -1 and 1, on press only")
    func paramButtons() throws {
        let rig = try Self.startedRig()
        Self.press(rig, 68)
        Self.press(rig, 69)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/BeatSkip", [.int(-1)]),
            OSCMessage("/Syndicate/Deck/1/BeatSkip", [.int(1)]),
        ])
    }

    @Test("Loop In, Loop Out and Auto Loop light full (127) while Syndicate reports Loop, and dim (1) when it ends")
    func loopLEDsFollowLoop() throws {
        let rig = try Self.startedRig()
        #expect([rig.leds[8], rig.leds[9], rig.leds[10]] == [1, 1, 1])

        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loop", [.int(1)]))
        #expect([rig.leds[8], rig.leds[9], rig.leds[10]] == [127, 127, 127])

        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loop", [.int(0)]))
        #expect([rig.leds[8], rig.leds[9], rig.leds[10]] == [1, 1, 1])
    }

    static func holdingShift(_ rig: Rig, _ body: () -> Void) {
        rig.coordinator.midi(.noteOn(channel: 0, note: 26, velocity: 127), source: Rig.lc6000.id)
        body()
        rig.coordinator.midi(.noteOff(channel: 0, note: 26, velocity: 0), source: Rig.lc6000.id)
    }

    @Test("Shift + Select press enters in the browser instead of loading")
    func shiftSelectEnters() throws {
        let rig = try Self.startedRig()
        Self.holdingShift(rig) { Self.press(rig, 18) }
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Browser/Enter", [.int(1)])])
    }

    @Test("Shift + beat jump ◀ and ▶ skip a bar instead of a beat")
    func shiftBeatJumpSkipsBar() throws {
        let rig = try Self.startedRig()
        Self.holdingShift(rig) {
            Self.press(rig, 3)
            Self.press(rig, 4)
        }
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/SkipBarBack", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/SkipBarForward", [.int(1)]),
        ])
    }

    @Test("The relative-tick boundary: 0x3F turns 63 steps down, 0x40 turns 64 steps up")
    func relativeTickBoundary() throws {
        let rig = try Self.startedRig()
        Self.turn(rig, cc: 6, 0x3F)
        #expect(rig.osc.sent == Array(repeating: OSCMessage("/Syndicate/Browser/Down", [.int(1)]), count: 63))
        rig.osc.sent.removeAll()
        Self.turn(rig, cc: 6, 0x40)
        #expect(rig.osc.sent == Array(repeating: OSCMessage("/Syndicate/Browser/Up", [.int(1)]), count: 64))
    }

    // #479: the knob is printed SELECT / ZOOM. With Shift held each click zooms the deck in front's waveform.

    static func shiftDown(_ rig: Rig) {
        rig.coordinator.midi(.noteOn(channel: 0, note: 26, velocity: 127), source: Rig.lc6000.id)
    }

    @Test("Shift + Select turn zooms the waveform: WaveformZoomIn 1 per clockwise click, WaveformZoomOut 1 per counter-clockwise; no browsing")
    func shiftTurnZooms() throws {
        let rig = try Self.startedRig()
        Self.shiftDown(rig)
        rig.osc.sent.removeAll()
        Self.turn(rig, cc: 6, 0x02)
        Self.turn(rig, cc: 6, 0x7F)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/WaveformZoomIn", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/WaveformZoomIn", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/WaveformZoomOut", [.int(1)]),
        ])
    }

    @Test("The zoom follows the deck in front (the mapping's deck)")
    func shiftTurnZoomsTheDeck() throws {
        let mapping = try Mapping.bundledDefault(overriddenBy: Data(#"{ "deck": { "number": 3 } }"#.utf8))
        let osc = Rig.FakeOSC()
        let coordinator = Coordinator(
            mapping: mapping,
            midi: Rig.FakeMIDISystem(sources: [Rig.lc6000], destinations: [Rig.lc6000Out]),
            osc: osc, clock: Rig.FakeClock(), log: Rig.FakeLog()
        )
        coordinator.start()
        coordinator.midi(.noteOn(channel: 0, note: 26, velocity: 127), source: Rig.lc6000.id)
        osc.sent.removeAll()
        coordinator.midi(.controlChange(channel: 0, controller: 6, value: 0x01), source: Rig.lc6000.id)
        #expect(osc.sent == [OSCMessage("/Syndicate/Deck/3/WaveformZoomIn", [.int(1)])])
    }

    @Test("Shift + Select press is still Enter")
    func shiftPressStillEnters() throws {
        let rig = try Self.startedRig()
        Self.shiftDown(rig)
        rig.osc.sent.removeAll()
        Self.press(rig, 18)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Browser/Enter", [.int(1)])])
    }
}
