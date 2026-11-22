import ControllerBridgeCore
import Foundation
import Testing

/// The platter ring in its deck's exact color (#530): with the color message on, the ring takes Denon's color message
/// (exact RGB, 7 bits a channel) in place of the 64-color note-on.
@Suite("Ring in exact color")
struct RingColorMessageTests {
    /// A started LC6000 on `deck`, with the color message on.
    static func exact(deck: Int = 1) throws -> Rig {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setColorMessages(true)
        rig.coordinator.setDeck(deck, controller: 0)
        return rig
    }

    static func output(_ rig: Rig) throws -> Rig.FakeOutput { try #require(rig.midi.outputs[Rig.lc6000Out.id]) }

    /// The color messages sent to `note`, each as [r, g, b].
    static func colors(_ rig: Rig, note: UInt8 = 40) throws -> [[UInt8]] {
        try output(rig).colors.filter { $0.note == note }.map { [$0.red, $0.green, $0.blue] }
    }

    static func palette(_ rig: Rig, slot: Int32, _ red: Int32, _ green: Int32, _ blue: Int32) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/ColorPalette", [.int(slot), .int(red), .int(green), .int(blue)]))
    }

    @Test("Loading a track lights the ring with one color message in the deck's exact color, top 7 bits, and no note-on")
    func trackLoad() throws {
        let rig = try Self.exact(deck: 2)
        Self.palette(rig, slot: 3, 255, 140, 0)
        let output = try Self.output(rig)
        output.sent.removeAll()
        output.colors.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        #expect(try Self.colors(rig) == [[127, 70, 0]])
        #expect(!output.sent.contains { if case .noteOn(_, 40, _) = $0 { true } else { false } })
    }

    @Test("Only changes go out: ticks send the ring nothing more; a deck color change sends the new color once")
    func onlyChanges() throws {
        let rig = try Self.exact(deck: 2)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        let before = try Self.colors(rig).count
        for step in 1...5 {
            rig.clock.now += 0.05 * Double(step)
            rig.coordinator.tick()
        }
        #expect(try Self.colors(rig).count == before)
        Self.palette(rig, slot: 3, 0, 255, 0)
        Self.palette(rig, slot: 3, 0, 255, 0)
        #expect(try Self.colors(rig).dropFirst(before) == [[0, 127, 0]])
    }

    @Test("Layers: only the layer in front sends color messages; the hidden deck's color change waits until it's shown")
    func layers() throws {
        // The color message carries no channel and Denon's firmware doesn't filter it by deck (#481), so a hidden
        // layer's message would paint the LEDs in front.
        let rig = try LayersTests.layered()
        rig.coordinator.setColorMessages(true)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        let output = try Self.output(rig)
        output.colors.removeAll()
        Self.palette(rig, slot: 3, 255, 0, 0)   // deck 2, hidden behind layer 1
        #expect(output.colors.isEmpty)
        LayersTests.note(rig, channel: 2, 51, 127)   // layer 2 to the front
        #expect(try Self.colors(rig).last == [127, 0, 0])
    }

    @Test("The ring held dark while the jog display uploads (#422): off as a color message, then its exact color again")
    func heldWhileUploading() throws {
        let (rig, port) = try JogDisplayRingHoldTests.owned()
        rig.coordinator.setColorMessages(true)
        let output = try #require(rig.midi.outputs[JogDisplayRingHoldTests.lc6000.id + 1000])
        output.sent.removeAll()   // the note-on from before the color message was on
        func ring() -> [[UInt8]] { output.colors.filter { $0.note == 40 }.map { [$0.red, $0.green, $0.blue] } }
        let lit = try #require(ring().last)
        #expect(lit != [0, 0, 0])
        let before = ring().count
        rig.coordinator.setJogDisplay(enabled: true)
        for _ in 0..<4 {
            let during = Array(ring().dropFirst(before))
            #expect(during.last == [0, 0, 0])
            #expect(!during.contains { $0 != [0, 0, 0] })
            JogDisplayRingHoldTests.answer(rig, port)
        }
        #expect(ring().last == lit)
        #expect(!output.sent.contains { if case .noteOn(_, 40, let v) = $0 { v > 0 } else { false } })
    }

    @Test("LEDs off turns the ring off with a color message; LEDs on brings its exact color back")
    func ledsSwitch() throws {
        let rig = try Self.exact(deck: 2)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        let lit = try #require(try Self.colors(rig).last)
        rig.coordinator.setLEDs(enabled: false)
        #expect(try Self.colors(rig).last == [0, 0, 0])
        rig.coordinator.setLEDs(enabled: true)
        #expect(try Self.colors(rig).last == lit)
    }

    @Test("After an LED sweep, whose note-ons override the unit's colors, the ring's color message goes out again")
    func afterSweep() throws {
        let rig = try Self.exact(deck: 1)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        let lit = try #require(try Self.colors(rig).last)
        rig.clock.now = 100
        rig.coordinator.startLEDSweep()
        let output = try Self.output(rig)
        output.colors.removeAll()
        DiagnosticsTests.tick(rig, at: 1000)
        #expect(!rig.coordinator.isSweeping)
        #expect(try Self.colors(rig).last == lit)
    }

    @Test("The way back (#530): with the table the ring takes its vivid note-on again; back to exact, its color message goes out again")
    func wayBack() throws {
        let rig = try Self.exact(deck: 2)
        Self.palette(rig, slot: 3, 255, 0, 0)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        let output = try Self.output(rig)
        rig.coordinator.apply(.setColorMessages(false))
        #expect(rig.leds[40] == 48)   // red on rgb222, as before #530
        output.colors.removeAll()
        rig.coordinator.apply(.setColorMessages(true))
        #expect(try Self.colors(rig) == [[127, 0, 0]])
    }

    @Test("The setting sent again unchanged (as at every launch) repaints nothing")
    func unchangedSettingSendsNothing() throws {
        let rig = try Self.exact(deck: 2)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        let output = try Self.output(rig)
        let before = output.writes.count
        rig.coordinator.apply(.setColorMessages(true))
        #expect(output.writes.count == before)
    }

    /// What the ring shows on the unit: the last write to note 40, a color message or a note-on.
    static func ringShows(_ output: Rig.FakeOutput) -> String? {
        for write in output.writes.reversed() {
            switch write {
            case .color(let m) where m.note == 40: return "color \(m.red) \(m.green) \(m.blue)"
            case .event(.noteOn(_, 40, let velocity)): return "note-on \(velocity)"
            default: continue
            }
        }
        return nil
    }

    @Test("The ring's last write stays its color message after a resync, LEDs off and on, an LED sweep and a reboot")
    func lastWriteWins() throws {
        let rig = try Self.exact(deck: 2)
        Self.palette(rig, slot: 3, 255, 0, 0)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        let red = "color 127 0 0"
        #expect(Self.ringShows(try Self.output(rig)) == red)
        // The sweep first: a resync left unanswered by this fake Syndicate goes stale over the sweep's minute.
        rig.clock.now = 100
        rig.coordinator.startLEDSweep()
        DiagnosticsTests.tick(rig, at: 1000)
        #expect(Self.ringShows(try Self.output(rig)) == red, "after a sweep")
        rig.coordinator.apply(.resync)
        #expect(Self.ringShows(try Self.output(rig)) == red, "resync")
        rig.coordinator.setLEDs(enabled: false)
        rig.coordinator.setLEDs(enabled: true)
        #expect(Self.ringShows(try Self.output(rig)) == red, "LEDs off and on")
        rig.coordinator.devicesChanged(removed: [Rig.lc6000.id])
        #expect(Self.ringShows(try Self.output(rig)) == red, "after a reboot")
    }

    @Test("Layers, both modes: a layer switch leaves the ring's last write the front deck's color message")
    func layerSwitchLastWrite() throws {
        for multiChannel in [false, true] {
            let rig = try LayersTests.layered()
            rig.coordinator.setColorMessages(true)
            Self.palette(rig, slot: 3, 255, 0, 0)
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
            if multiChannel {
                LayersTests.note(rig, channel: 1, 51, 0); LayersTests.note(rig, channel: 2, 51, 127)
                LayersTests.note(rig, channel: 2, 1, 127)   // Play on ch2: controls on ch2
            } else {
                LayersTests.note(rig, channel: 2, 51, 127)
            }
            let output = try Self.output(rig)
            #expect(Self.ringShows(output) == "color 127 0 0", "multi-channel: \(multiChannel)")
            // The hidden deck 1's color change paints nothing.
            output.colors.removeAll()
            Self.palette(rig, slot: 1, 0, 0, 255)
            #expect(output.colors.isEmpty, "multi-channel: \(multiChannel)")
        }
    }

    @Test("With no track the ring is off, as a color message of 0, 0, 0")
    func noTrack() throws {
        let rig = try Self.exact(deck: 2)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(0)]))
        #expect(try Self.colors(rig).last == [0, 0, 0])
    }
}
