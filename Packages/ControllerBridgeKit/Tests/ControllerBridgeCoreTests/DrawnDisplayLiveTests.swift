import Foundation
@testable import ControllerBridgeCore
import Testing

/// The drawn display's needle, master beat and play state (#459), through the Coordinator on a fake display port.
@Suite("Drawn display: needle, master beat and play state")
struct DrawnDisplayLiveTests {
    typealias Handshake = DrawnDisplayHandshakeTests

    /// Drawn mode, deck 1 loaded and playing at 120 BPM from BarRamp 0 at t = 0.
    static func playing() throws -> (ProfileMatchingTests.ProfileRig, Handshake.Port) {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        for (path, value) in [("Playing", OSCArgument.int(1)), ("BPM", .float(120)), ("BarRamp", .float(0))] {
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/" + path, [value]))
        }
        port.wd.removeAll()
        return (rig, port)
    }

    static func ops(_ port: Handshake.Port, _ op: UInt8) -> [[UInt8]] { Handshake.drawn(port).filter { $0[9] == op } }

    @Test("Drawing: the needle goes out as op 09, 50 a second, and never as pitch bend")
    func needleAsMessage() throws {
        let (rig, port) = try Self.playing()
        for step in 1...100 {
            rig.clock.now = Double(step) * 0.01
            // Syndicate's BarRamp each beat (half a second at 120): a quarter of the bar each time.
            if step % 50 == 0 { rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/BarRamp", [.float(Float(step) / 200)])) }
            rig.coordinator.tick()
        }
        let needles = Self.ops(port, 0x09)
        #expect(needles.count == 50)   // ticks at 0.01 to 1.00: the first is due, then every second one
        #expect(!port.wd.contains { $0.first == 0xE0 })
        // Nearly a second on at 120 BPM: close to half a bar, 8192 (the last send may be up to 20 ms earlier).
        let last = needles.last.map { Int($0[10]) << 7 | Int($0[11]) } ?? 0
        #expect((8000...8192).contains(last))
    }

    @Test("Paused, the needle holds: no needle message while nothing changes")
    func pausedHolds() throws {
        let (rig, port) = try Self.playing()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))
        rig.clock.now = 0.5
        rig.coordinator.tick()
        port.wd.removeAll()
        for step in 1...50 {
            rig.clock.now = 0.5 + Double(step) * 0.02
            rig.coordinator.tick()
        }
        #expect(Self.ops(port, 0x09).isEmpty)
    }

    static func clock(_ rig: ProfileMatchingTests.ProfileRig, _ beat: Int) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Header/Clock", [.int(Int32(beat))]))
    }

    @Test("Each master beat sends one beat message, a repeat sends none, and no image is shown while drawing")
    func beatPerBeat() throws {
        let (rig, port) = try Self.playing()
        for beat in [1, 2, 2, 3, 4, 1] { Self.clock(rig, beat) }
        #expect(Self.ops(port, 0x08).map { $0[10] } == [1, 2, 3, 4, 1])
        #expect(!port.wd.contains { $0.count > 6 && $0[0] == 0xF0 && $0[6] == 0x0A })
    }

    @Test("With no master clock: the full state's beat is 0 (no section lit), and the needle still moves")
    func noClock() throws {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        #expect(Self.ops(port, 0x08).map { $0[10] } == [0])
        for (path, value) in [("Playing", OSCArgument.int(1)), ("BPM", .float(120)), ("BarRamp", .float(0))] {
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/" + path, [value]))
        }
        rig.clock.now = 0.25
        rig.coordinator.tick()
        #expect(!Self.ops(port, 0x09).isEmpty)
    }

    @Test("The state carries loaded, playing and play pending for the deck in front; only changes go out")
    func stateFlags() throws {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)   // deck 1 loaded
        rig.coordinator.tick()
        port.wd.removeAll()
        func step(_ path: String, _ value: Int32) {
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/" + path, [.int(value)]))
            rig.coordinator.tick()
        }
        step("Playing", 1)
        step("Playing", 1)
        step("Playing", 0)
        step("PlayPending", 1)
        step("PlayPending", 0)
        step("Playing", 1)
        #expect(Self.ops(port, 0x07).map { $0[10] } == [0x03, 0x01, 0x05, 0x01, 0x03])
    }

    @Test("Drawing, no play light (note 1) goes out; neither does a pitch bend")
    func noStockMessagesWhileDrawing() throws {
        let (rig, port) = try Self.playing()
        for step in 1...60 {
            rig.clock.now = Double(step) * 0.01
            rig.coordinator.tick()
        }
        #expect(!port.wd.contains { $0.first == 0x90 && $0.count > 1 && $0[1] == 0x01 })
        #expect(!port.wd.contains { $0.first == 0xE0 })
    }

    @Test("Hand-back: drawing, a deck change, then Firmware set to Denon: the current needle as pitch bend, end, then deck 2's images go up")
    func handBack() throws {
        let (rig, port) = try Handshake.drawnLayers()
        let unit = JogDisplayRingHoldTests.lc6000.id
        for (path, value) in [("Playing", OSCArgument.int(1)), ("BPM", .float(120)), ("BarRamp", .float(0))] {
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/" + path, [value]))
        }
        rig.coordinator.midi(.noteOn(channel: 0, note: 51, velocity: 0), source: unit)
        rig.coordinator.midi(.noteOn(channel: 1, note: 51, velocity: 127), source: unit)
        rig.clock.now = 0.25
        rig.coordinator.tick()
        let needle = try #require(Handshake.drawn(port).last { $0[9] == 0x09 }).suffix(3).prefix(2)
        let angle = Int(needle.first!) << 7 | Int(needle.last!)
        port.wd.removeAll()
        rig.coordinator.setDisplayFirmware(.denon)
        let bend = try #require(port.wd.firstIndex { $0.first == 0xE0 })
        let end = try #require(port.wd.firstIndex(of: DrawnDisplay.Message.end(version: 1).bytes))
        let upload = try #require(port.wd.firstIndex { $0.count > 6 && $0[0] == 0xF0 && $0[6] == 0x0C })
        #expect(bend < end && end < upload)
        #expect(port.wd[bend] == [0xE0, UInt8(angle & 0x7F), UInt8(angle >> 7)])
        #expect(JogDisplaySlotCacheTests.uploadSlots(port).first.map { (5...8).contains($0) } == true)
    }

    /// #592's stall: at ~97 drawn messages a second the unit's USB dropped. Every needle, meter, phase, beat or time
    /// message makes the chip redraw (~14 ms a step, #563); messages that arrive together cost one redraw (dfw_tick
    /// parses what's waiting, then draws once). So the needle, the meter and the phase share one 20 ms cadence (#605), and the
    /// windows with any redraw message stay within `JogDisplayController.redrawBudget`.
    @Test("Everything moving at once (needle, meter every tick, a nudge, beats at 180 BPM, the time): at most redrawBudget redraw windows a second")
    func redrawBudget() throws {
        #expect(JogDisplayController.redrawBudget == 54)
        let (rig, port) = try Self.playing()
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        port.wd.removeAll()
        var windows = 0
        for step in 0..<100 {
            let time = 1 + Double(step) * 0.01
            rig.clock.now = time
            let before = Self.redraws(port)
            rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH1/Meter", [.float(step % 2 == 0 ? 0.3 : 0.9)]))
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/PhaseOffset", [.float(-0.01 - Float(step) * 0.001)]))
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Position", [.float(Float(time) * 10)]))
            if step % 33 == 0 {
                rig.coordinator.feedback(OSCMessage("/Syndicate/Header/BPM", [.float(180)]))
                rig.coordinator.feedback(OSCMessage("/Syndicate/Header/Clock", [.int(Int32(step / 33 % 4 + 1))]))
            }
            rig.coordinator.tick()
            if Self.redraws(port) > before { windows += 1 }
        }
        #expect(windows <= JogDisplayController.redrawBudget)
        #expect(windows >= 50)   // the live cadence alone
    }

    /// The drawn messages that make the chip redraw: time, beat, needle, meter and phase.
    static func redraws(_ port: Handshake.Port) -> Int {
        Handshake.drawn(port).filter { [0x06, 0x08, 0x09, 0x0A, 0x0B].contains($0[9]) }.count
    }
}
