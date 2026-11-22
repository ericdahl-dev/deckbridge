import Foundation
@testable import ControllerBridgeCore
import Testing

/// The jog display's master beat on time (#720), through the Coordinator on a fake display port and clock: the beat
/// message the display already gets goes when the beat clock says it's due, not when Syndicate's message arrives.
@Suite("Jog display beat timing")
struct JogDisplayBeatTimingTests {
    typealias Live = DrawnDisplayLiveTests
    typealias Rig = ProfileMatchingTests.ProfileRig

    /// The beats the drawn display got (op 08), in order.
    static func beats(_ port: DrawnDisplayHandshakeTests.Port) -> [UInt8] { Live.ops(port, 0x08).map { $0[10] } }

    /// Ticks every 10 ms from the clock's now to `until` (seconds).
    static func tick(_ rig: Rig, until: Double) {
        while rig.clock.now < until - 1e-9 {
            rig.clock.now = ((rig.clock.now + 0.01) * 100).rounded() / 100
            rig.coordinator.tick()
        }
    }

    /// Syndicate's master beat arriving now.
    static func clock(_ rig: Rig, _ beat: Int, at time: Double) {
        tick(rig, until: time)
        Live.clock(rig, beat)
    }

    @Test("Drawing: the next beat goes when it's due, before Syndicate's message for it, and only once")
    func nextBeatBeforeItsMessage() throws {
        let (rig, port) = try Live.playing()
        Self.clock(rig, 1, at: 1.00)
        Self.clock(rig, 2, at: 1.47)  // 470 ms a beat
        Self.tick(rig, until: 1.93)
        #expect(Self.beats(port) == [1, 2])
        Self.tick(rig, until: 1.94)   // due at 1.94
        #expect(Self.beats(port) == [1, 2, 3])
        Self.clock(rig, 3, at: 1.97)  // Syndicate's message, 30 ms behind
        Self.tick(rig, until: 2.00)
        #expect(Self.beats(port) == [1, 2, 3])
    }

    @Test("With Syndicate's master BPM one beat is enough: the next goes a beat length on, before its message")
    func masterBPMTimesTheFirstBeat() throws {
        let (rig, port) = try Live.playing()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Header/BPM", [.float(120)]))
        Self.clock(rig, 1, at: 1.00)
        Self.tick(rig, until: 1.49)
        #expect(Self.beats(port) == [1])
        Self.tick(rig, until: 1.50)
        #expect(Self.beats(port) == [1, 2])
    }

    @Test("Denon's images (beat mode): the next beat's slot shows when it's due, before its message, and only once")
    func slotShowBeforeItsMessage() throws {
        typealias Slots = JogDisplayBeatSlotTests
        let rig = try ControllerBridgeCoreTests.Rig()
        let (port, _) = Slots.attach(rig)
        Slots.clock(rig, 3)
        rig.coordinator.start()
        _ = Slots.uploadAll(rig, port)
        port.wd.removeAll()
        func at(_ time: Double, _ beat: Int? = nil) {
            while rig.clock.now < time - 1e-9 {
                rig.clock.now = ((rig.clock.now + 0.01) * 100).rounded() / 100
                rig.coordinator.tick()
            }
            if let beat { Slots.clock(rig, beat) }
        }
        // The uploads' beat (3, at 0) is long before: a gap, so the run starts at 4.
        at(2.00, 4)
        at(2.47, 1)
        at(2.93)
        #expect(Slots.shows(port) == [4, 1])
        at(2.94)
        #expect(Slots.shows(port) == [4, 1, 2])
        at(2.97, 2)
        at(3.00)
        #expect(Slots.shows(port) == [4, 1, 2])
    }

    /// Deck 1 (playing, drawn) as the master or not, the master beat 1 and 2 heard, then deck 1 pauses at 1.80.
    static func pausedAfterTwoBeats(master: Bool) throws -> DrawnDisplayHandshakeTests.Port {
        let (rig, port) = try Live.playing()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Sync", [.int(master ? 1 : 0)]))
        Self.clock(rig, 1, at: 1.00)
        Self.clock(rig, 2, at: 1.47)
        Self.tick(rig, until: 1.80)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))
        Self.tick(rig, until: 2.50)
        return port
    }

    @Test("The master deck stops: so did the master clock, so no beat goes ahead of a message")
    func masterStopsTheClock() throws {
        #expect(Self.beats(try Self.pausedAfterTwoBeats(master: true)) == [1, 2])
    }

    @Test("Another deck's pause says nothing about the master clock: the next beat still goes when due")
    func otherDeckPauseKeepsTheClock() throws {
        #expect(Self.beats(try Self.pausedAfterTwoBeats(master: false)) == [1, 2, 3])
    }
}
