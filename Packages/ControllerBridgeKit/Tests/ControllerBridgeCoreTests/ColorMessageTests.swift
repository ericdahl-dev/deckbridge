import ControllerBridgeCore
import Foundation
import Testing

/// True colors with no firmware (#530, #474): Denon's top panel firmware takes a color message on the Controller port,
/// `F0 00 02 0B 7F 10 03 00 04 <note> <r> <g> <b> F7`, 7 bits a channel (#481, proven on the owner's unit). A profile
/// declares which of its LEDs take it.
@Suite("Color message")
struct ColorMessageTests {
    static func problems(_ leds: String) -> [String] { Mapping.problems(in: Data(#"{"leds": \#(leds)}"#.utf8)) }

    @Test("The LC6000's pads and ring (notes 32-40) take the color message; a profile without the key has none")
    func profileKey() throws {
        let lc6000 = try Mapping.bundledDefault()
        #expect(lc6000.leds.colorMessage?.notes == Array(32...40))
        #expect(ProfileKeys.key("leds.color_message.notes[]")?.range == 0...127)
        var leds = lc6000.leds
        leds.colorMessage = nil
        let decoded = try JSONDecoder().decode(Mapping.LEDs.self, from: JSONEncoder().encode(leds))
        #expect(decoded.colorMessage == nil)
    }

    @Test("The check takes a list of notes 0-127 and refuses anything else")
    func checkedNotes() {
        #expect(Self.problems(#"{"color_message": {"notes": [32, 40]}}"#) == [])
        #expect(Self.problems(#"{"color_message": {"notes": [128]}}"#) == [
            "leds.color_message.notes[0]: 128 is out of range, expected 0-127",
        ])
        #expect(Self.problems(#"{"color_message": {"notes": 40}}"#) == [
            "leds.color_message.notes: expected a list, got 40",
        ])
    }

    /// LEDColorMessage has no public initializer: the encoder is the only way to make one, so these are all the bytes
    /// the app can ever send this way.
    @Test("The encoder makes only command 03, for a listed note that is the ring or a pad, each channel 0-127")
    func encoderGuard() throws {
        let lc6000 = try Mapping.bundledDefault()
        let encoder = try #require(LEDColorEncoder(lc6000))
        let values = [-5, 0, 1, 2, 127, 128, 200, 254, 255, 300]
        for note in 0...127 {
            let listed = (32...40).contains(note)
            for r in values {
                for g in values {
                    for b in values {
                        let message = encoder.message(note: note, rgb: [r, g, b])
                        guard listed else {
                            #expect(message == nil, "note \(note)")
                            continue
                        }
                        let seven = { (v: Int) in UInt8(min(max(v, 0), 255) >> 1) }
                        #expect(message?.bytes == [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x03, 0x00, 0x04, UInt8(note),
                                                   seven(r), seven(g), seven(b), 0xF7])
                    }
                }
            }
        }
    }

    @Test("A listed note that isn't the ring or a pad of this profile makes nothing; neither does a profile without the key")
    func strayNotes() throws {
        var mapping = try Mapping.bundledDefault()
        mapping.notes.pads = [32, 33, 34, 35]
        let encoder = try #require(LEDColorEncoder(mapping))
        #expect(encoder.message(note: 35, rgb: [255, 0, 0]) != nil)
        #expect(encoder.message(note: 36, rgb: [255, 0, 0]) == nil)
        #expect(encoder.message(note: 40, rgb: [255, 0, 0]) != nil)
        mapping.leds.colorMessage = nil
        #expect(LEDColorEncoder(mapping) == nil)
    }
}
