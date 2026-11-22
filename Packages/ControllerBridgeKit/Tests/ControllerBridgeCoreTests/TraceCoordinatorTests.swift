import Foundation
@testable import ControllerBridgeCore
import Testing

/// The Coordinator's trace hook (#395): what a Debug build logs, whether or not Diagnostics is open.
@Suite("Debug trace at the Coordinator")
struct TraceCoordinatorTests {
    final class Lines: @unchecked Sendable {
        var list: [(TraceCategory, String)] = []
        func of(_ category: TraceCategory) -> [String] { list.filter { $0.0 == category }.map(\.1) }
    }

    static func traced() throws -> (Rig, Lines) {
        let rig = try Rig()
        let lines = Lines()
        rig.coordinator.trace = { category, text in lines.list.append((category, text)) }
        rig.coordinator.start()
        lines.list.removeAll()
        return (rig, lines)
    }

    @Test("MIDI in, with its port, channel and mapping name; the OSC it sends")
    func midiInAndOSCOut() throws {
        let (rig, lines) = try Self.traced()
        rig.coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        #expect(lines.of(.midiIn) == ["DENON LC6000 PRIME ch1 note_on channel=0 note=1 velocity=127 time=0 play"])
        #expect(lines.of(.oscOut) == ["/Syndicate/Deck/1/PlayPause 1"])
    }

    @Test("OSC in, and the LED MIDI it sends out, with port and channel")
    func oscInAndMIDIOut() throws {
        let (rig, lines) = try Self.traced()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        #expect(lines.of(.oscIn) == ["/Syndicate/Deck/1/Playing 1"])
        #expect(lines.of(.midiOut).contains("DENON LC6000 PRIME ch1 note_on channel=0 note=1 velocity=127 time=0"))
    }

    @Test("A color message (#530) is a readable MIDI out line: port, the LED's name, and its red, green and blue")
    func colorMessage() throws {
        let (rig, lines) = try Self.traced()
        rig.coordinator.setColorMessages(true)
        rig.coordinator.feedback(OSCMessage("/Syndicate/ColorPalette", [.int(1), .int(255), .int(140), .int(0)]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        #expect(lines.of(.midiOut).contains("DENON LC6000 PRIME color ring r=127 g=70 b=0"))
    }

    @Test("Streaming feedback is sampled: 20 Positions in 100 ms keep the first")
    func sampled() throws {
        let (rig, lines) = try Self.traced()
        for i in 0..<20 {
            rig.clock.now = 50 + Double(i) * 0.005
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Position", [.float(Float(i))]))
        }
        #expect(lines.of(.oscIn) == ["/Syndicate/Deck/1/Position 0.0"])
    }

    @Test("QuantizeOverride: which deck, which reason, in or out, and what was sent")
    func quantize() throws {
        let (rig, lines) = try Self.traced()
        ShiftCuePausedTests.feed(rig, "Playing", 0)
        ShiftCuePausedTests.shiftPad(rig)
        ShiftCuePausedTests.feed(rig, "Playing", 1)
        #expect(lines.of(.quantize) == ["deck 1 cueJump in: Quantize None", "deck 1 cueJump out: Quantize Use Global"])
    }

    @Test("Log lines (connects, problems) go to the trace as coordinator lines too")
    func logLines() throws {
        let rig = try Rig()
        let lines = Lines()
        rig.coordinator.trace = { category, text in lines.list.append((category, text)) }
        rig.coordinator.start()
        #expect(lines.of(.coordinator).contains("LEDs go to DENON LC6000 PRIME"))
    }
}
