@testable import ControllerBridgeCore
import Testing

/// The phase message at the Coordinator (#462): the front deck's PhaseOffset, as DrawnPhase makes it, on change and at
/// most 30 a second; a known one in the full state and the heartbeat; image mode sends none.
@Suite("Drawn display: phase from the deck")
struct DrawnDisplayPhaseFlowTests {
    typealias Handshake = DrawnDisplayHandshakeTests

    static func phases(_ port: Handshake.Port) -> [[UInt8]] { phases(port.wd) }
    static func phases(_ port: JogDisplayDriverTests.FakePort) -> [[UInt8]] { phases(port.wd) }
    static func phases(_ wd: [[UInt8]]) -> [[UInt8]] { Handshake.drawn(wd).filter { $0[9] == 0x0B } }
    static func offset(_ beats: Float, deck: Int = 1) -> OSCMessage {
        OSCMessage("/Syndicate/Deck/\(deck)/PhaseOffset", [.float(beats)])
    }
    static func playing(_ on: Bool, deck: Int = 1) -> OSCMessage {
        OSCMessage("/Syndicate/Deck/\(deck)/Playing", [.int(on ? 1 : 0)])
    }

    /// The coordinator's clock and the driver's, moved together.
    struct Clocks {
        let rig: ProfileMatchingTests.ProfileRig, driver: Rig.FakeClock
        var now: Double {
            get { driver.now }
            nonmutating set { rig.clock.now = newValue; driver.now = newValue }
        }
    }

    /// Drawing deck 1, loaded and playing; WD cleared.
    static func drawing() throws -> (ProfileMatchingTests.ProfileRig, Handshake.Port, Clocks) {
        let (rig, port, clock) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        rig.coordinator.feedback(Self.playing(true))
        rig.coordinator.tick()
        port.wd.removeAll()
        return (rig, port, Clocks(rig: rig, driver: clock))
    }

    @Test("A playing deck's offset goes as op 0B; the same again sends nothing")
    func onChange() throws {
        let (rig, port, clock) = try Self.drawing()
        clock.now = 1
        rig.coordinator.feedback(Self.offset(-0.04))
        rig.coordinator.tick()
        #expect(Self.phases(port) == [DrawnDisplay.Message.phase(-655).bytes])
        port.wd.removeAll()
        clock.now = 1.1
        rig.coordinator.feedback(Self.offset(-0.04))
        rig.coordinator.tick()
        #expect(Self.phases(port).isEmpty)
    }

    @Test("Stopping the deck sends unknown: the chip draws the plain rule")
    func stopping() throws {
        let (rig, port, clock) = try Self.drawing()
        clock.now = 1
        rig.coordinator.feedback(Self.offset(0.01))
        rig.coordinator.tick()
        port.wd.removeAll()
        clock.now = 1.1
        rig.coordinator.feedback(Self.playing(false))
        rig.coordinator.tick()
        #expect(Self.phases(port) == [DrawnDisplay.Message.phase(-8192).bytes])
    }

    @Test("A nudge (Syndicate sends about 45 a second): under the 50 a second live cadence (#605) every change goes, and the last value too")
    func rateLimited() throws {
        let (rig, port, clock) = try Self.drawing()
        for step in 0..<45 {
            clock.now = 2 + Double(step) / 45
            rig.coordinator.feedback(Self.offset(-0.01 - Float(step) * 0.001))
            rig.coordinator.tick()
        }
        // A tick every 22 ms is always due on a 20 ms cadence, and each offset is new: all 45.
        #expect(Self.phases(port).count == 45)
        // The last offset, -0.054 beat, is -885 on the wire: sent by the end of the nudge or on the next due tick.
        clock.now = 3.1
        rig.coordinator.tick()
        #expect(Self.phases(port).last == DrawnDisplay.Message.phase(-885).bytes)
    }

    @Test("The heartbeat carries a known phase, after the meter")
    func heartbeat() throws {
        let (rig, port, clock) = try Self.drawing()
        clock.now = 0.5
        rig.coordinator.feedback(Self.offset(-0.04))
        rig.coordinator.tick()
        port.wd.removeAll()
        clock.now = 1.0
        rig.coordinator.tick()
        let ops = DrawnDisplayReconnectTests.ops(port)
        #expect(Array(ops.suffix(2)) == [0x0A, 0x0B])
        #expect(Self.phases(port) == [DrawnDisplay.Message.phase(-655).bytes])
    }

    @Test("Image mode sends no phase")
    func notInImages() throws {
        let (rig, port, clock) = try Handshake.rig(.custom)
        clock.now = 0.5
        rig.clock.now = 0.5
        rig.coordinator.tick()
        port.wd.removeAll()
        rig.coordinator.feedback(Self.playing(true))
        rig.coordinator.feedback(Self.offset(-0.04))
        rig.clock.now = 1
        rig.coordinator.tick()
        #expect(Self.phases(port).isEmpty)
    }

    @Test("A deck switch: the new deck's phase goes on the next tick, even one equal to the old deck's (the chip forgot it)")
    func deckSwitch() throws {
        let (rig, port) = try Handshake.drawnLayers()
        for deck in 1...2 {
            rig.coordinator.feedback(Self.playing(true, deck: deck))
            rig.coordinator.feedback(Self.offset(0.01, deck: deck))
        }
        rig.clock.now = 1
        rig.coordinator.tick()
        port.wd.removeAll()
        rig.coordinator.midi(.noteOn(channel: 0, note: 51, velocity: 0), source: JogDisplayRingHoldTests.lc6000.id)
        rig.coordinator.midi(.noteOn(channel: 1, note: 51, velocity: 127), source: JogDisplayRingHoldTests.lc6000.id)
        rig.clock.now = 1.01
        rig.coordinator.tick()
        let drawn = Handshake.drawn(port)
        #expect(drawn.first?[9] == 0x03 && drawn.first?[10] == 2)
        #expect(Self.phases(port) == [DrawnDisplay.Message.phase(164).bytes])
    }
}

@Suite("Drawn display: phase's subscription")
struct DrawnDisplayPhaseSubscriptionTests {
    typealias Handshake = DrawnDisplayHandshakeTests

    @Test("While drawing, PhaseOffset joins the required subscriptions; not before, not after")
    func required() throws {
        let (rig, _, _) = try Handshake.rig(.custom)
        #expect(!rig.coordinator.status.requiredSubscriptions.contains(.phaseOffset))   // still asking
        rig.coordinator.jogDisplayReply(Handshake.answer)
        #expect(rig.coordinator.status.requiredSubscriptions.contains(.phaseOffset))
        rig.coordinator.setJogDisplay(enabled: false)
        #expect(!rig.coordinator.status.requiredSubscriptions.contains(.phaseOffset))
    }

    @Test("A Resend's answer for a loaded deck with no PhaseOffset reports it missing; with one, nothing")
    func judged() {
        let answer = EverySubscriptionTests.deck1.map(\.1)
        let required = Subscription.always + [.phaseOffset]
        #expect(SubscriptionCheck(answer: answer, required: required)?.missing == [.phaseOffset])
        let with = answer + [OSCMessage("/Syndicate/Deck/1/PhaseOffset", [.float(0)])]
        #expect(SubscriptionCheck(answer: with, required: required)?.missing == [])
    }

    @Test("What it breaks names the jog display's phase rule and the display feed's phase (#617)")
    func breaks() {
        #expect(Subscription.phaseOffset.syndicateName == "PhaseOffset")
        #expect(Subscription.phaseOffset.breaks
            == "the jog display's rule doesn't show the deck's phase, and the display feed sends its phase as unknown")
    }
}
