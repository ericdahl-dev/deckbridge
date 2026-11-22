import Foundation
@testable import ControllerBridgeCore
import Testing

/// The drawn display recovers by itself (#464): a full state send after begin, again after a replug or reboot (the chip
/// forgets drawn mode at every boot, #466), and the stale flag while Syndicate's feedback is stopped.
@Suite("Drawn display: reconnect, reboot and stale feedback")
struct DrawnDisplayReconnectTests {
    typealias Handshake = DrawnDisplayHandshakeTests

    /// The op byte of each drawn-display message on WD, in order.
    static func ops(_ port: Handshake.Port) -> [UInt8] { Handshake.drawn(port).map { $0[9] } }

    @Test("Begin, then the full state: the deck, then the state, each once, in that order; no upload")
    func fullStateAfterBegin() throws {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        // ... and (#459) the master beat, 0 with no clock yet; no needle until one is known.
        // ... and (#461) the meter, empty until the deck's channel reports.
        #expect(Self.ops(port) == [0x00, 0x01, 0x03, 0x07, 0x04, 0x04, 0x04, 0x04, 0x05, 0x08, 0x0A])
        #expect(Handshake.drawn(port).last == DrawnDisplay.Message.meter(level: 0, peak: 0).bytes)
        #expect(!port.wd.contains(where: Handshake.isUpload))
    }

    /// The unit power-cycled quickly (#429): its WD port removed and back with the same id.
    static func replug(_ rig: ProfileMatchingTests.ProfileRig) {
        rig.coordinator.devicesChanged(removed: [JogDisplayRingHoldTests.wd.id, JogDisplayRingHoldTests.lc6000.id])
    }

    @Test("WD removed and back while drawing: hello, the question, and on the answer begin and the full state again; no upload")
    func replugDrawsAgain() throws {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        port.wd.removeAll(); port.controller.removeAll()
        Self.replug(rig)
        #expect(port.controller.suffix(2) == JogDisplay.hello)
        #expect(Self.ops(port).last == 0x00)
        port.wd.removeAll()
        rig.coordinator.jogDisplayReply(Handshake.answer)
        #expect(Self.ops(port) == [0x01, 0x03, 0x07, 0x04, 0x04, 0x04, 0x04, 0x05, 0x08, 0x0A])
        #expect(!port.wd.contains(where: Handshake.isUpload))
    }

    @Test("#604 replayed: power cycled while drawing (the controller, then WD, removed and back), no answer while the chip starts, then answers 7 s on: drawn again with no relaunch")
    func powerCycleSlowChipDrawsAgain() throws {
        let (rig, port, clock) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        // Two CoreMIDI notifications, as in the owner's log at 04:28:44: the controller's endpoints, then WD's.
        rig.coordinator.devicesChanged(removed: [JogDisplayRingHoldTests.lc6000.id])
        rig.coordinator.devicesChanged(removed: [JogDisplayRingHoldTests.wd.id])
        #expect(port.controller.suffix(2) == JogDisplay.hello)
        for step in 1...700 {   // 7 s: the 0.5 s wait runs out, images, and the question again at 1.5 and 3.5 s
            clock.now = Double(step) / 100
            rig.coordinator.tick()
        }
        #expect(rig.coordinator.status.displayFound?.label == "Custom (images)")
        port.wd.removeAll()
        rig.coordinator.jogDisplayReply(Handshake.answer)   // the chip has started
        #expect(Array(Self.ops(port).prefix(3)) == [0x01, 0x03, 0x07])
        #expect(rig.coordinator.status.displayFound?.label == "Custom (drawn display, protocol 1)")
    }

    @Test("Replugged on Denon's firmware (no answer): images after half a second, as on a first connect")
    func replugOnDenon() throws {
        let (rig, port, clock) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        Self.replug(rig)
        port.wd.removeAll()
        clock.now = 0.5
        rig.coordinator.tick()
        #expect(Handshake.uploadSlots(port) == [1])
        #expect(Self.ops(port).isEmpty)
        #expect(rig.coordinator.status.displayFound?.label == "Custom (images)")
    }

    @Test("Syndicate's feedback stops: the state goes out with the stale flag; fresh feedback clears it; only changes go out")
    func staleFlag() throws {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        rig.clock.now = 0.5
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))
        rig.coordinator.tick()   // the deck's loaded flag (#459)
        port.wd.removeAll()
        for time in [10.5, 12.5, 13.0] {
            rig.clock.now = time
            rig.coordinator.tick()
        }
        #expect(rig.coordinator.status.feedback == .stale)
        // Stale, then (#459) Syndicate's deck state cleared, as the LEDs' is: the deck isn't known loaded any more.
        #expect(Handshake.drawn(port) == [DrawnDisplay.Message.state([.loaded, .stale]).bytes,
                                          DrawnDisplay.Message.state(.stale).bytes])
        port.wd.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))
        rig.coordinator.tick()
        #expect(rig.coordinator.status.feedback == .live)
        #expect(Handshake.drawn(port) == [DrawnDisplay.Message.state([]).bytes])
    }

    @Test("A deck switch while drawing: the deck message, then the state, so the chip has the new deck's flags")
    func deckSwitchCarriesState() throws {
        let (rig, port) = try DrawnDisplayHandshakeTests.drawnLayers()
        port.wd.removeAll()
        rig.coordinator.midi(.noteOn(channel: 0, note: 51, velocity: 0), source: JogDisplayRingHoldTests.lc6000.id)
        rig.coordinator.midi(.noteOn(channel: 1, note: 51, velocity: 127), source: JogDisplayRingHoldTests.lc6000.id)
        #expect(DrawnDisplayHandshakeTests.drawn(port).map { $0[9] } == [0x03, 0x07, 0x04, 0x04, 0x04, 0x04, 0x05])
    }

    @Test("Heartbeat while drawing: begin, the deck and the state again once a second, unchanged or not")
    func heartbeat() throws {
        let (rig, port, clock) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        rig.coordinator.tick()   // the deck's loaded flag (#459)
        let full = [DrawnDisplay.Message.begin(version: 1).bytes] + Handshake.drawn(port).filter { $0[9] == 0x03 }
            + [DrawnDisplay.Message.state(.loaded).bytes] + Handshake.drawn(port).filter { $0[9] == 0x04 || $0[9] == 0x05 }
            + [DrawnDisplay.Message.beat(0).bytes, DrawnDisplay.Message.time(elapsedSeconds: 0, lengthSeconds: 0).bytes,
               DrawnDisplay.Message.meter(level: 0, peak: 0).bytes]
        port.wd.removeAll()
        clock.now = 0.99
        rig.coordinator.tick()
        #expect(Self.ops(port).isEmpty)
        clock.now = 1.0
        rig.coordinator.tick()
        #expect(Handshake.drawn(port) == Array(full))
        port.wd.removeAll()
        clock.now = 1.5
        rig.coordinator.tick()
        #expect(Self.ops(port).isEmpty)
        clock.now = 2.0
        rig.coordinator.tick()
        #expect(Self.ops(port) == [0x01, 0x03, 0x07, 0x04, 0x04, 0x04, 0x04, 0x05, 0x08, 0x06, 0x0A])
    }

    @Test("No heartbeat in image mode")
    func noHeartbeatForImages() throws {
        let (rig, port, clock) = try Handshake.rig(.custom)
        clock.now = 0.5
        rig.coordinator.tick()
        port.wd.removeAll()
        for time in [1.5, 2.5, 5.0] {
            clock.now = time
            rig.coordinator.tick()
        }
        // The capability question again (#604) is the only drawn op: no begin, no deck, no state.
        #expect(Self.ops(port).allSatisfy { $0 == 0x00 })
    }
}
