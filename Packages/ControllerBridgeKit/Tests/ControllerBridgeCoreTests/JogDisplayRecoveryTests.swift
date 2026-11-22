import Foundation
@testable import ControllerBridgeCore
import Testing

/// A jog display port that stopped taking data takes it again (#595). What was dropped meanwhile, needle steps or an
/// upload's chunks, is worthless, so the display starts over as after a replug: goodbye, hello and the question, then on
/// the answer begin and the full state. A port that wedges again at once is restarted at most every few seconds.
@Suite("Jog display: a port that takes data again")
struct JogDisplayRecoveryTests {
    typealias Handshake = DrawnDisplayHandshakeTests

    final class Lines: @unchecked Sendable { var list: [(TraceCategory, String)] = [] }

    static func drawing() throws -> (ProfileMatchingTests.ProfileRig, Handshake.Port, Rig.FakeClock, Lines) {
        let (rig, port, clock) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        let lines = Lines()
        rig.coordinator.trace = { category, text in lines.list.append((category, text)) }
        port.wd.removeAll(); port.controller.removeAll()
        return (rig, port, clock, lines)
    }

    static func at(_ time: Double, _ rig: ProfileMatchingTests.ProfileRig, _ clock: Rig.FakeClock) {
        rig.clock.now = time
        clock.now = time
    }

    @Test("Drawing, the port comes back: goodbye, hello and the question; on the answer begin and the full state, no upload")
    func restartsDrawing() throws {
        let (rig, port, _, _) = try Self.drawing()
        rig.coordinator.apply(.jogDisplayRecovered)
        #expect(port.controller == [JogDisplay.goodbye] + JogDisplay.hello)
        #expect(DrawnDisplayReconnectTests.ops(port).last == 0x00)
        port.wd.removeAll()
        rig.coordinator.jogDisplayReply(Handshake.answer)
        #expect(DrawnDisplayReconnectTests.ops(port) == [0x01, 0x03, 0x07, 0x04, 0x04, 0x04, 0x04, 0x05, 0x08, 0x0A])
        #expect(!port.wd.contains(where: Handshake.isUpload))
    }

    @Test("Wedged again at once: one restart now, the next not before 3 s after it, and the trace says so once")
    func backsOff() throws {
        let (rig, port, clock, lines) = try Self.drawing()
        Self.at(10, rig, clock)
        rig.coordinator.apply(.jogDisplayRecovered)                       // restarts
        port.controller.removeAll()
        for time in [10.5, 11.0, 12.0] {                                  // back, stuck, back again...
            Self.at(time, rig, clock)
            rig.coordinator.apply(.jogDisplayRecovered)
            rig.coordinator.tick()
        }
        Self.at(12.9, rig, clock)
        rig.coordinator.tick()
        // A restart is its goodbye: the hello's own re-sends (#606) go on the same port meanwhile.
        #expect(!port.controller.contains(JogDisplay.goodbye), "no restart inside the back-off")
        Self.at(13.0, rig, clock)
        rig.coordinator.tick()
        #expect(Array(port.controller.drop { $0 != JogDisplay.goodbye }) == [JogDisplay.goodbye] + JogDisplay.hello,
                "one restart when it ends")
        let said = lines.list.filter { $0.0 == .jogDisplay && $0.1.contains("again within") }
        #expect(said.count == 1)
        port.controller.removeAll()
        Self.at(14, rig, clock)
        rig.coordinator.tick()
        #expect(!port.controller.contains(JogDisplay.goodbye), "nothing pending after it")
    }
}
