import ControllerBridgeCore
import Foundation
import Testing

/// Pacing for color messages (#531): a gap between messages, one constant, 0 until a burst test on the unit says
/// otherwise. A repaint sends nine (8 pads + ring) at once.
@Suite("Color pacer")
struct ColorPacerTests {
    static func message(_ note: Int, _ red: Int) throws -> LEDColorMessage {
        try #require(LEDColorEncoder(try Mapping.bundledDefault())?.message(note: note, rgb: [red, 0, 0]))
    }

    static func notes(_ messages: [LEDColorMessage]) -> [String] { messages.map { "\($0.note):\($0.red)" } }

    @Test("With no gap every message goes out at once: the pacing in use until the unit says otherwise")
    func noGap() throws {
        var pacer = ColorPacer(gap: 0)
        for note in 32...40 { #expect(Self.notes(pacer.send(try Self.message(note, 254), at: 5)) == ["\(note):127"]) }
        #expect(pacer.tick(at: 5).isEmpty)
    }

    @Test("With a gap: one message, then the rest one per gap on ticks, in the order they came")
    func gap() throws {
        var pacer = ColorPacer(gap: 0.01)
        #expect(Self.notes(pacer.send(try Self.message(32, 254), at: 1)) == ["32:127"])
        #expect(pacer.send(try Self.message(33, 254), at: 1).isEmpty)
        #expect(pacer.send(try Self.message(34, 254), at: 1).isEmpty)
        #expect(pacer.tick(at: 1.005).isEmpty)
        #expect(Self.notes(pacer.tick(at: 1.01)) == ["33:127"])
        #expect(Self.notes(pacer.tick(at: 1.05)) == ["34:127"])
        #expect(pacer.tick(at: 2).isEmpty)
        // Once the gap has passed, a new message goes straight out again.
        #expect(Self.notes(pacer.send(try Self.message(35, 254), at: 3)) == ["35:127"])
    }

    @Test("A newer color for an LED still waiting replaces it, keeping its place in the queue")
    func newerReplaces() throws {
        var pacer = ColorPacer(gap: 0.01)
        _ = pacer.send(try Self.message(32, 254), at: 1)
        _ = pacer.send(try Self.message(33, 254), at: 1)
        _ = pacer.send(try Self.message(34, 254), at: 1)
        _ = pacer.send(try Self.message(33, 100), at: 1)
        #expect(Self.notes(pacer.tick(at: 1.01)) == ["33:50"])
        #expect(Self.notes(pacer.tick(at: 1.02)) == ["34:127"])
    }
}
