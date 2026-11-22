@testable import ControllerBridgeCore
import Testing

/// The drawn display's protocol, defined once in vectors/messages.json (#569): DrawnDisplayProtocol.swift is generated
/// from it. This fails if the generated file is out of date (regenerate with vectors/gen_protocol.py).
@Suite("Drawn display: the one protocol description")
struct DrawnDisplayProtocolTests {
    static var protocolEntry: [String: Any] { DrawnDisplayVectorsTests.file["protocol"] as! [String: Any] }

    @Test("Every op's number and length are the description's")
    func ops() {
        let ops = Self.protocolEntry["ops"] as! [[String: Any]]
        #expect(ops.count == DrawnDisplayProtocol.Op.allCases.count)
        for op in ops {
            let number = UInt8(op["op"] as! Int), name = op["name"] as! String
            let generated = DrawnDisplayProtocol.Op(rawValue: number)
            #expect(generated.map { "\($0)" } == name, "\(name)")
            #expect(DrawnDisplayProtocol.length(number) == op["length"] as? Int, "\(name)")
        }
    }

    @Test("The caps, flag bits, framing and reserved values are the description's")
    func constants() {
        let entry = Self.protocolEntry
        let caps = entry["caps"] as! [String: Int], flags = entry["flags"] as! [String: Int]
        let timing = entry["timing"] as! [String: Int]
        #expect(DrawnDisplayProtocol.textMax == caps["text_max"] && DrawnDisplayProtocol.textFields == caps["text_fields"])
        #expect(DrawnDisplayProtocol.messageMax == caps["message_max"] && DrawnDisplayProtocol.deckMax == caps["deck_max"])
        #expect(DrawnDisplayProtocol.playerMax == caps["player_max"] && DrawnDisplayProtocol.beatMax == caps["beat_max"])
        #expect(DrawnDisplayProtocol.flagBits == flags)
        #expect(DrawnDisplayProtocol.command == entry["command"] as? Int && DrawnDisplayProtocol.version == entry["version"] as? Int)
        #expect(DrawnDisplayProtocol.phaseUnknown == entry["phase_unknown"] as? Int)
        #expect(DrawnDisplayProtocol.silenceMs == timing["silence_ms"] && DrawnDisplayProtocol.blinkHalfMs == timing["blink_half_ms"])
        #expect(DrawnDisplayProtocol.warningSeconds == timing["warning_seconds"]
                && DrawnDisplayProtocol.blinkSeconds == timing["blink_seconds"])
        #expect(DrawnDisplayProtocol.header == [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10])
        #expect(DrawnDisplayProtocol.replyHeader == [0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10])
    }
}
