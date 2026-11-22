import Foundation
@testable import ControllerBridgeCore
import Testing

/// Loop and cue state on the drawn display (#463): the state message carries the front deck's loop on (bit 4, from
/// Syndicate's Loop) and cue held (bit 3, the CUE button down), sent on change, cleared at the next tick when they end.
@Suite("Drawn display: loop and cue state")
struct DrawnDisplayLoopCueTests {
    typealias Handshake = DrawnDisplayHandshakeTests

    /// Drawing, deck 1 loaded, the loaded flag already sent; WD cleared.
    static func drawing() throws -> (ProfileMatchingTests.ProfileRig, Handshake.Port) {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        rig.coordinator.tick()
        port.wd.removeAll()
        return (rig, port)
    }

    static func states(_ port: Handshake.Port) -> [[UInt8]] { Handshake.drawn(port).filter { $0[9] == 0x07 } }

    @Test("Syndicate's Loop on: the state goes out with loop on; Loop off clears it; each once")
    func loop() throws {
        let (rig, port) = try Self.drawing()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loop", [.int(1)]))
        rig.coordinator.tick()
        rig.coordinator.tick()
        #expect(Self.states(port) == [DrawnDisplay.Message.state([.loaded, .loopOn]).bytes])
        port.wd.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loop", [.int(0)]))
        rig.coordinator.tick()
        #expect(Self.states(port) == [DrawnDisplay.Message.state(.loaded).bytes])
    }

    @Test("CUE held: the state goes out with cue held; releasing it clears it at the next tick")
    func cue() throws {
        let (rig, port) = try Self.drawing()
        let unit = JogDisplayRingHoldTests.lc6000.id
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: unit)
        rig.coordinator.tick()
        #expect(Self.states(port).last == DrawnDisplay.Message.state([.loaded, .cueHeld]).bytes)
        port.wd.removeAll()
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 0), source: unit)
        rig.coordinator.tick()
        #expect(Self.states(port).last.map { DrawnDisplay.State(rawValue: $0[10]).contains(.cueHeld) } == false)
    }
}
