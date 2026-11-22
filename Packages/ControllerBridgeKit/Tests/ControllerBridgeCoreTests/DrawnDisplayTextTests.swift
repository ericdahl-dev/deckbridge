@testable import ControllerBridgeCore
import Testing

/// The drawn display's text and tempo messages (#458), from agent3's wire spec: op 04 `<field> <escaped chars>`,
/// Windows-1252, a code 0x80-0xFF as 7F then code − 0x80, control codes dropped, a character with no cp1252 code as
/// 0x81 (the chip's box). Op 05 tempo in tenths, 14-bit.
@Suite("Drawn display: text and tempo")
struct DrawnDisplayTextTests {
    static let head: [UInt8] = [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x20]

    /// The frame for op 04 with these bytes after the field.
    static func text(_ field: UInt8, _ chars: [UInt8]) -> [UInt8] {
        let len = 2 + chars.count
        return head + [UInt8(len >> 7), UInt8(len & 0x7F), 0x04, field] + chars + [0xF7]
    }

    @Test("Plain ASCII goes as itself, after the field")
    func ascii() {
        #expect(DrawnDisplay.Message.text(.title, "Daybreak").bytes == Self.text(0, Array("Daybreak".utf8)))
        #expect(DrawnDisplay.Message.text(.key, "A#m").bytes == Self.text(2, Array("A#m".utf8)))
    }

    @Test("Empty text is the field alone: it clears that field")
    func empty() {
        #expect(DrawnDisplay.Message.text(.artist, "").bytes == Self.text(1, []))
    }

    @Test("Codes 0x80-0xFF go escaped: é 7F 69, — 7F 17, … 7F 05, € 7F 00")
    func escaped() {
        #expect(DrawnDisplay.Message.text(.artist, "Café").bytes == Self.text(1, Array("Caf".utf8) + [0x7F, 0x69]))
        #expect(DrawnDisplay.Message.text(.title, "A—B…€").bytes
                == Self.text(0, [0x41, 0x7F, 0x17, 0x42, 0x7F, 0x05, 0x7F, 0x00]))
    }

    @Test("A decomposed é (e + combining accent) is still one cp1252 code")
    func decomposed() {
        #expect(DrawnDisplay.Message.text(.title, "Cafe\u{301}").bytes == Self.text(0, Array("Caf".utf8) + [0x7F, 0x69]))
    }

    @Test("Control codes and DEL aren't text: dropped")
    func controls() {
        #expect(DrawnDisplay.Message.text(.title, "A\u{7}\tB\u{7F}\nC").bytes == Self.text(0, Array("ABC".utf8)))
    }

    @Test("A character with no cp1252 code goes as 0x81, escaped (7F 01): one box per character")
    func noGlyph() {
        #expect(DrawnDisplay.Message.text(.title, "日本").bytes == Self.text(0, [0x7F, 0x01, 0x7F, 0x01]))
        #expect(DrawnDisplay.Message.text(.title, "a🎵b").bytes == Self.text(0, [0x61, 0x7F, 0x01, 0x62]))
        // C1 controls have no glyph either; cp1252's unassigned slots must not leak through as themselves.
        #expect(DrawnDisplay.Message.text(.title, "\u{81}\u{8D}").bytes == Self.text(0, [0x7F, 0x01, 0x7F, 0x01]))
    }

    @Test("The untitled words go in field 3")
    func untitledField() {
        #expect(DrawnDisplay.Message.text(.untitled, "Automation").bytes == Self.text(3, Array("Automation".utf8)))
    }

    @Test("Text is cut to the cap of escaped bytes, at a character boundary: the whole message stays at most 108 bytes")
    func cut() {
        let cap = DrawnDisplay.textCap
        #expect(cap == 96)
        let long = String(repeating: "a", count: cap + 10)
        #expect(DrawnDisplay.Message.text(.title, long).bytes == Self.text(0, Array(repeating: 0x61, count: cap)))
        #expect(DrawnDisplay.Message.text(.title, long).bytes.count == 108)
        // Exactly the cap fits whole.
        let exact = String(repeating: "a", count: cap)
        #expect(DrawnDisplay.Message.text(.title, exact).bytes == Self.text(0, Array(exact.utf8)))
    }

    @Test("A 7F pair is never split: one byte short of room for é, the é goes, the a's before it stay")
    func cutKeepsPairs() {
        let cap = DrawnDisplay.textCap
        let text = String(repeating: "a", count: cap - 1) + "é" + "b"
        #expect(DrawnDisplay.Message.text(.title, text).bytes == Self.text(0, Array(repeating: 0x61, count: cap - 1)))
    }

    static func tempo(_ tenths: Int) -> [UInt8] { head + [0x00, 0x03, 0x05, UInt8(tenths >> 7), UInt8(tenths & 0x7F)] + [0xF7] }

    @Test("Tempo in tenths of a BPM, rounded once, 14-bit hi/lo: 128.0 is 1280, 127.96 is 1280, 99.94 is 999")
    func tempo() {
        #expect(DrawnDisplay.Message.tempo(128).bytes == Self.tempo(1280))
        #expect(DrawnDisplay.Message.tempo(127.96).bytes == Self.tempo(1280))
        #expect(DrawnDisplay.Message.tempo(99.94).bytes == Self.tempo(999))
    }

    @Test("No tempo is 0: nil, NaN, zero or negative. Above 1638.3 BPM it clamps to 16383")
    func tempoEdges() {
        for bpm in [nil, Double.nan, 0, -120] as [Double?] { #expect(DrawnDisplay.Message.tempo(bpm).bytes == Self.tempo(0)) }
        #expect(DrawnDisplay.Message.tempo(2000).bytes == Self.tempo(16383))
        #expect(DrawnDisplay.Message.tempo(.infinity).bytes == Self.tempo(16383))
        #expect(DrawnDisplay.Message.tempo(0.01).bytes == Self.tempo(0))
    }
}
