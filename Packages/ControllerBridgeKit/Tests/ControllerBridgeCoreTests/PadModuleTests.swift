import Foundation
@testable import ControllerBridgeCore
import Testing

/// The pads as a module (#383 slice 5): plain values in, sends out; the Bridge applies them.
@Suite("Pad module: mode")
struct PadModuleModeTests {
    static let lc6000 = try! Mapping.bundledDefault()

    /// A profile with one cycling mode button (#198) and notes per mode (#225).
    static func ddj() throws -> Mapping {
        let json = #"""
            { "notes": { "mode_cycle": 108 }, "pads": { "mode_select": "cycle",
                        "mode_notes": { "hotcue": [32, 33, 34, 35, 36, 37, 38, 39], "roll": [112, 113, 114, 115, 116, 117, 118, 119],
                                        "loop": [96, 97, 98, 99, 100, 101, 102, 103], "slicer": [120, 121, 122, 123, 124, 125, 126, 127] } } }
            """#
        return try Mapping.bundledDefault(overriddenBy: Data(json.utf8))
    }

    @Test("A mode button lets held pads go, then switches")
    func modeButton() {
        var pads = PadModule(mapping: Self.lc6000)
        #expect(pads.mode == .hotCue)
        #expect(pads.modeButton(.roll) == [.releasePads])
        #expect(pads.mode == .roll)
    }

    @Test("The cycle button goes Hot Cue → Roll → Loop → Slicer → Hot Cue on a cycle profile; the LC6000's does nothing")
    func cycle() throws {
        var pads = PadModule(mapping: try Self.ddj())
        var seen: [PadMode] = []
        for _ in 0..<4 {
            _ = pads.cycle()
            seen.append(pads.mode)
        }
        #expect(seen == [.roll, .loop, .slicer, .hotCue])
        var lc6000 = PadModule(mapping: Self.lc6000)
        #expect(lc6000.cycle() == [])
        #expect(lc6000.mode == .hotCue)
    }

    @Test("A note from another mode's list (#225) switches to that mode, letting held pads go, and plays that pad")
    func modeNotes() throws {
        var pads = PadModule(mapping: try Self.ddj())
        let press = pads.press(note: 114)
        #expect(press?.index == 2)
        #expect(press?.sends == [.releasePads])
        #expect(pads.mode == .roll)
        let again = pads.press(note: 115)
        #expect(again?.sends == [], "same mode: nothing to let go")
        #expect(pads.press(note: 1) == nil, "not a pad: Play")
        #expect(pads.notes(for: .loop) == [96, 97, 98, 99, 100, 101, 102, 103])
    }

    @Test("A settings swap carries the pad mode to the new bridge's module (#115)")
    func carry() {
        var old = PadModule(mapping: Self.lc6000)
        _ = old.modeButton(.loop)
        var new = PadModule(mapping: Self.lc6000)
        new.carry(from: old)
        #expect(new.mode == .loop)
    }

    @Test("Without notes per mode, notes.pads plays in every mode")
    func plainPads() {
        var pads = PadModule(mapping: Self.lc6000)
        #expect(pads.press(note: 32)?.index == 0)
        #expect(pads.notes(for: .roll) == Self.lc6000.notes.pads)
    }
}

@Suite("Pad module: what a press does")
struct PadModuleActionTests {
    static let lc6000 = PadModuleModeTests.lc6000
    static let still = PadModule.Facts(shift: false, playing: true, playPending: false)

    @Test("Hot Cue: hold HotCue n 1, release n 0; a pad past Syndicate's 8 cues does nothing")
    func hotCue() {
        let pads = PadModule(mapping: Self.lc6000)
        #expect(pads.pressed(2, Self.still) == [.hold(2, "HotCue", press: [.int(3), .int(1)], release: [.int(3), .int(0)])])
        #expect(pads.released(2) == [.release(2)])
        #expect(pads.pressed(8, Self.still) == [])
    }

    @Test("Shift on a stopped deck: the cue jump (#358), not a hot cue; playing, or a start pending, it's a hot cue")
    func shiftStopped() {
        let pads = PadModule(mapping: Self.lc6000)
        #expect(pads.pressed(1, PadModule.Facts(shift: true, playing: false, playPending: false)) == [.cueJump(2)])
        #expect(pads.pressed(1, PadModule.Facts(shift: true, playing: true, playPending: false))
            == [.hold(1, "HotCue", press: [.int(2), .int(1)], release: [.int(2), .int(0)])])
        #expect(pads.pressed(1, PadModule.Facts(shift: true, playing: false, playPending: true))
            == [.hold(1, "HotCue", press: [.int(2), .int(1)], release: [.int(2), .int(0)])])
    }

    @Test("Roll: hold the pad's slip loop size (#196). Loop: SetCueLoop n. Slicer: nothing")
    func otherModes() {
        var pads = PadModule(mapping: Self.lc6000)
        _ = pads.modeButton(.roll)
        #expect(pads.pressed(0, Self.still) == [.hold(0, "SlipLoop/ThirtySecond", press: [.int(1)], release: [.int(0)])])
        #expect(pads.pressed(7, Self.still) == [.hold(7, "SlipLoop/Four", press: [.int(1)], release: [.int(0)])])
        _ = pads.modeButton(.loop)
        #expect(pads.pressed(4, Self.still) == [.osc("SetCueLoop", .int(5))])
        _ = pads.modeButton(.slicer)
        #expect(pads.pressed(0, Self.still) == [])
    }
}

@Suite("Pad module: cues, palette and pad colors")
struct PadModuleColorTests {
    static let lc6000 = PadModuleModeTests.lc6000

    /// Cues feedback: a slot and a name per cue.
    static func cues(_ slots: [Int]) -> [OSCArgument] { slots.flatMap { [OSCArgument.int(Int32($0)), .string("c")] } }

    @Test("Hot Cue: each cue in its palette color (slot 1 red = 48), empty off; held, the brightest version (#151)")
    func hotCueColors() {
        var pads = PadModule(mapping: Self.lc6000)
        pads.cuesFeedback(Self.cues([1, 0, 9, 0, 0, 0, 0, 0]))
        // Slot 9 isn't in the palette yet: white, 0x3F. Then the palette gives it a dim red: 32, and 48 held.
        #expect(pads.velocities(held: [], ringColors: .exact) == [48, 0, 0x3F, 0, 0, 0, 0, 0])
        let applied = pads.paletteFeedback([.int(9), .int(128), .int(0), .int(0)])
        #expect(applied)
        #expect(pads.velocities(held: [], ringColors: .exact) == [48, 0, 32, 0, 0, 0, 0, 0])
        #expect(pads.velocities(held: [2], ringColors: .exact) == [48, 0, 48, 0, 0, 0, 0, 0])
        let short = pads.paletteFeedback([.int(1), .int(2)])
        #expect(!short, "fewer than four numbers: ignored")
    }

    @Test("Roll: every pad with a roll size in the roll color (56). Loop: cues in the loop color (12). Slicer: off")
    func otherModes() {
        var pads = PadModule(mapping: Self.lc6000)
        pads.cuesFeedback(Self.cues([1, 0, 4, 0, 0, 0, 0, 8]))
        _ = pads.modeButton(.roll)
        #expect(pads.velocities(held: [], ringColors: .exact) == [56, 56, 56, 56, 56, 56, 56, 56])
        _ = pads.modeButton(.loop)
        #expect(pads.velocities(held: [], ringColors: .exact) == [12, 0, 12, 0, 0, 0, 0, 12])
        _ = pads.modeButton(.slicer)
        #expect(pads.velocities(held: [], ringColors: .exact) == [0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test("Clearing the cues (a track gone) and carrying them across a settings swap (#115)")
    func clearAndCarry() {
        var pads = PadModule(mapping: Self.lc6000)
        pads.cuesFeedback(Self.cues([1, 2, 0, 0, 0, 0, 0, 0]))
        _ = pads.paletteFeedback([.int(2), .int(0), .int(0), .int(255)])
        var new = PadModule(mapping: Self.lc6000)
        new.carryFeedback(from: pads)
        #expect(new.cues == [1, 2, 0, 0, 0, 0, 0, 0])
        #expect(new.velocities(held: [], ringColors: .exact) == pads.velocities(held: [], ringColors: .exact))
        pads.clearCues(count: 8)
        #expect(pads.cues == [0, 0, 0, 0, 0, 0, 0, 0])
    }
}

/// The LED caches (#383 slice 5d): an unchanged LED is never sent twice; pads on their own channel (#224) are their own
/// cache, since a pad's note can be a button's on another channel.
@Suite("LED cache")
struct LEDCacheTests {
    @Test("A new velocity goes out; the same again doesn't; another one does")
    func writes() {
        var cache = LEDCache()
        var out: [Bool] = []
        out.append(cache.write(1, 127, onPads: false))
        out.append(cache.write(1, 127, onPads: false))
        out.append(cache.write(1, 0, onPads: false))
        #expect(out == [true, false, true])
    }

    @Test("Pads and buttons are separate: note 1 on the pads' channel isn't note 1's button")
    func separate() {
        var cache = LEDCache()
        var out: [Bool] = []
        out.append(cache.write(1, 48, onPads: false))
        out.append(cache.write(1, 48, onPads: true))
        out.append(cache.write(1, 48, onPads: true))
        #expect(out == [true, true, false])
    }

    @Test("A flush forgets everything, so the next writes all go out (a repaint)")
    func flush() {
        var cache = LEDCache()
        _ = cache.write(1, 127, onPads: false)
        _ = cache.write(32, 48, onPads: true)
        cache.flush()
        var out: [Bool] = []
        out.append(cache.write(1, 127, onPads: false))
        out.append(cache.write(32, 48, onPads: true))
        #expect(out == [true, true])
    }

    @Test("What each cache shows, note order, for turning the LEDs off")
    func shown() {
        var cache = LEDCache()
        _ = cache.write(9, 1, onPads: false)
        _ = cache.write(3, 127, onPads: false)
        _ = cache.write(33, 0, onPads: true)
        _ = cache.write(32, 48, onPads: true)
        #expect(cache.shown(onPads: false) == [LEDCache.Lit(note: 3, velocity: 127), LEDCache.Lit(note: 9, velocity: 1)])
        #expect(cache.shown(onPads: true) == [LEDCache.Lit(note: 32, velocity: 48), LEDCache.Lit(note: 33, velocity: 0)])
    }
}
