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

    /// Drawn mode playing, with the jog display's beat lead set to `lead` (seconds).
    static func playing(lead: Double) throws -> (Rig, DrawnDisplayHandshakeTests.Port) {
        let (rig, port) = try Live.playing()
        rig.coordinator.apply(.setJogBeatLead(lead))
        return (rig, port)
    }

    @Test("Drawing: the next beat goes when it's due, before Syndicate's message for it, and only once")
    func nextBeatBeforeItsMessage() throws {
        let (rig, port) = try Self.playing(lead: 0)
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
        let (rig, port) = try Self.playing(lead: 0)
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
        rig.coordinator.apply(.setJogBeatLead(0))
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
        let (rig, port) = try Self.playing(lead: 0)
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

    /// When the third beat (due at 1.94, beats at 1.00 and 1.47) first went out; nil if it didn't by 1.97.
    static func thirdBeatSent(_ rig: Rig, _ port: DrawnDisplayHandshakeTests.Port) -> Double? {
        Self.clock(rig, 1, at: 1.00)
        Self.clock(rig, 2, at: 1.47)
        while rig.clock.now < 1.97 - 1e-9 {
            Self.tick(rig, until: rig.clock.now + 0.01)
            if Self.beats(port).count == 3 { return rig.clock.now }
        }
        return nil
    }

    @Test("The jog display's beat goes 40 ms early by default: the owner's lead on the unit, 2026-11-22")
    func defaultLead() throws {
        let (rig, port) = try Live.playing()
        let sent = try #require(Self.thirdBeatSent(rig, port))
        #expect(abs(sent - 1.90) < 1e-6)
    }

    @Test("The lead setting is kept to 0-200 ms (cos, #720)",
          arguments: [(-0.010, 1.94), (0.0, 1.94), (0.100, 1.84), (0.200, 1.74), (0.250, 1.74)])
    func leadSetting(lead: Double, sentAt: Double) throws {
        let (rig, port) = try Self.playing(lead: lead)
        let sent = try #require(Self.thirdBeatSent(rig, port))
        #expect(abs(sent - sentAt) < 1e-6)
    }

    @Test("16 beats at the default lead, some messages 30 ms late: each beat goes once, in order, and nothing else")
    func steadyBeatsOnceEach() throws {
        let (rig, port) = try Live.playing()
        let expected = (0..<16).map { UInt8($0 % 4 + 1) }
        for k in 0..<16 {
            let due = 1.00 + Double(k) * 0.47
            Self.clock(rig, Int(expected[k]), at: due + (k % 5 == 3 ? 0.03 : 0))
        }
        Self.tick(rig, until: 8.10)  // the last at 8.05; the next goes at 8.46
        #expect(Self.beats(port) == expected)
    }

    @Test("The master stops after its next beat went early: the display steps back to the beat heard (the panel's model)")
    func stopAfterEarlyBeatStepsBack() throws {
        let (rig, port) = try Live.playing()  // the default 60 ms lead
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Sync", [.int(1)]))
        Self.clock(rig, 1, at: 1.00)
        Self.clock(rig, 2, at: 1.47)
        Self.tick(rig, until: 1.90)  // 3 went at 1.88
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))
        Self.tick(rig, until: 2.50)
        #expect(Self.beats(port) == [1, 2, 3, 2])
    }

    @Test("The once-a-second heartbeat resends the beat on screen, a predicted one too: never another value, so no flicker")
    func heartbeatResendsTheBeatShown() throws {
        // The driver's own clock too (Handshake's), so its heartbeat comes due as in the app.
        let (rig, port, driverClock) = try DrawnDisplayHandshakeTests.rig(.custom)
        rig.coordinator.jogDisplayReply(DrawnDisplayHandshakeTests.answer)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        port.wd.removeAll()
        // 128 BPM from 1.00 s with the default 60 ms lead; each beat's message 15 ms after it's due.
        var heard = 0
        while rig.clock.now < 6.0 - 1e-9 {
            let now = ((rig.clock.now + 0.01) * 100).rounded() / 100
            rig.clock.now = now
            driverClock.now = now
            let due = Int(((now - 1.0 - 0.015) / 0.46875).rounded(.down))
            if now >= 1.015, due >= heard { Live.clock(rig, due % 4 + 1); heard = due + 1 }
            rig.coordinator.tick()
        }
        let drawn = DrawnDisplayHandshakeTests.drawn(port)
        var heartbeats = 0, shown: UInt8? = 0   // the handshake's full state: beat 0, none lit
        for (index, message) in drawn.enumerated() where message[9] == 0x08 {
            let afterBegin = drawn[..<index].last { $0[9] == 0x01 || $0[9] == 0x08 }?[9] == 0x01
            if afterBegin {
                heartbeats += 1
                #expect(message[10] == shown, "a heartbeat at op \(index) sent \(message[10]), the screen showed \(String(describing: shown))")
            } else {
                shown = message[10]
            }
        }
        #expect(heartbeats >= 4)
    }
}
