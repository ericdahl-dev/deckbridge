import ControllerBridgeCore
import Foundation
import Testing

/// A debug capture of Syndicate's full-rate meter stream (#582), to decide the meter's scale from data: every
/// Mixer/CHn/Meter value with its time for `seconds`, nothing else, handed over once as CSV. The trace keeps only 5 a
/// second of it, so it can't answer that.
@Suite("Meter capture")
struct MeterCaptureTests {
    final class Captured: @unchecked Sendable { var files: [String] = [] }

    @Test("Every Meter value for 10 s, at full rate, then one CSV; other feedback isn't in it; a second capture can follow")
    func capture() throws {
        let rig = try Rig()
        rig.coordinator.start()
        let captured = Captured()
        rig.coordinator.meterCaptureSink = { captured.files.append($0) }
        rig.clock.now = 100
        rig.coordinator.apply(.startMeterCapture(seconds: 10))
        for step in 0..<2200 {   // 200 a second for 11 s
            rig.clock.now = 100 + Double(step) * 0.005
            rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH\(step % 2 + 1)/Meter", [.float(Float(step % 7) / 5)]))
            if step % 100 == 0 { rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Position", [.float(1)])) }
            if step % 2 == 0 { rig.coordinator.tick() }
        }
        #expect(captured.files.count == 1)
        let lines = try #require(captured.files.first).split(separator: "\n")
        #expect(lines.first == "seconds,channel,value")
        #expect(lines.count == 1 + 2000)
        #expect(lines[1] == "0.000,1,0.0000")
        #expect(lines[3] == "0.010,1,0.4000")
        #expect(!lines.contains { $0.contains("Position") })
    }
}
