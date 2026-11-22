import Foundation
@testable import ControllerBridgeCore
import Testing

/// The jog display's hello goes to the LC6000's Controller port, the same port as its LEDs (#426). At launch the LEDs
/// were painted 3 ms before the hello, and only LEDs that changed afterwards showed; turning the LEDs off and on
/// fixed it. So the controller that owns the display paints every LED again after the hello.
@Suite("Jog display hello repaint")
struct JogDisplayHelloRepaintTests {
    /// Every note-on sent to the LC6000's LED output, in order.
    static func sent(_ rig: ProfileMatchingTests.ProfileRig) -> [(note: UInt8, velocity: UInt8)] {
        let out = rig.midi.outputs[JogDisplayRingHoldTests.lc6000.id + 1000]?.sent ?? []
        return out.compactMap { if case .noteOn(_, let note, let velocity) = $0 { (note, velocity) } else { nil } }
    }

    @Test("Turning the display on: after its hello, every LED painted at start goes out again, the ring at 0 for the uploads")
    func repaintAfterHello() throws {
        let (rig, port) = try JogDisplayRingHoldTests.owned()
        let painted = Set(Self.sent(rig).map(\.note))
        let before = Self.sent(rig).count
        rig.coordinator.setJogDisplay(enabled: true)
        #expect(port.controller.contains(JogDisplay.hello.last ?? []))
        let after = Array(Self.sent(rig).dropFirst(before))
        #expect(Set(after.map(\.note)).isSuperset(of: painted))
        #expect(after.last { $0.note == 40 }?.velocity == 0)
    }
}
