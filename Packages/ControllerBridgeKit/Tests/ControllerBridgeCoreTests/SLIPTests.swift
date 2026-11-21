import Foundation
@testable import ControllerBridgeCore
import Testing

/// The display feed over the USB cable (#667): tools/deck-panel/feed/slip.json holds packets and their SLIP frames,
/// written by hand. The panel's serial_feed test walks the same file.
@Suite("Display feed: SLIP frames for the USB cable")
struct SLIPTests {
    static var cases: [[String: String]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/deck-panel/feed/slip.json")
        let file = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return file["cases"] as! [[String: String]]
    }

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    @Test("the file has its cases")
    func theFileHasItsCases() {
        #expect(Self.cases.count >= 6)
    }

    @Test("each packet is framed as the shared examples say", arguments: cases)
    func eachPacketIsFramedAsTheSharedExamplesSay(_ example: [String: String]) {
        let packet = Self.bytes(example["packet_hex"]!)
        #expect(SLIP.frame(packet) == Self.bytes(example["framed_hex"]!), "\(example["name"]!)")
    }
}
