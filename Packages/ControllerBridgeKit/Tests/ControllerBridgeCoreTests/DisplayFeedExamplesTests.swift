import Foundation
@testable import ControllerBridgeCore
import Testing

/// The display feed's shared examples (#490 seam 3, #616): tools/deck-panel/feed/examples.json says, for each deck
/// state, the messages the feed sends for it. This walks it on the Swift side; the panel core's test (#619) walks the
/// same file, so the two can't drift. A key this walker doesn't know (a later field, #617) is left for its own test.
@Suite("Display feed: the shared examples")
struct DisplayFeedExamplesTests {
    static var file: [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/deck-panel/feed/examples.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static var cases: [[String: Any]] { file["cases"] as! [[String: Any]] }

    /// One expected message: its type is the OSC type tag itself, i, f or s.
    static func message(_ entry: [String: Any]) -> OSCMessage? {
        let address = entry["address"] as! String
        switch entry["type"] as! String {
        case "i": return OSCMessage(address, [.int(Int32(entry["value"] as! Int))])
        case "f": return OSCMessage(address, [.float((entry["value"] as! NSNumber).floatValue)])
        case "s": return OSCMessage(address, [.string(entry["value"] as! String)])
        default: return nil
        }
    }

    static func deck(_ state: [String: Any]) -> DisplayFeed.Deck {
        DisplayFeed.Deck(number: state["deck"] as! Int, color: state["color"] as! [Int], loaded: state["loaded"] as? Bool ?? false,
                         title: state["title"] as? String ?? "", artist: state["artist"] as? String ?? "",
                         key: state["key"] as? String ?? "", bpm: state["bpm"] as? Double ?? 0, tempo: state["tempo"] as? Double ?? 0,
                         playing: state["playing"] as? Bool ?? false, cue: state["cue"] as? Bool ?? false,
                         sync: state["sync"] as? Bool ?? false, master: state["master"] as? Bool ?? false,
                         loop: state["loop"] as? Bool ?? false, loopLength: state["loopLength"] as? Double ?? 0,
                         beat: state["beat"] as? Int ?? 0, clockBpm: state["clockBpm"] as? Double ?? 0, elapsed: state["elapsed"] as? Int ?? 0,
                         remaining: state["remaining"] as? Int ?? 0, progress: state["progress"] as? Double ?? 0,
                         phase: state["phase"] as? Double ?? -1,
                         level: state["level"] as? Double ?? 0)
    }

    @Test("Every address the snapshot sends has its row in ADR 0011's contract, with its OSC type (#674)")
    func contractRows() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/adr/0011-display-feed-to-other-devices.md")
        let adr = try String(contentsOf: url, encoding: .utf8)
        for message in DisplayFeed.Deck(number: 1, color: [255, 0, 0]).messages {
            let name = String(message.address.dropFirst(DisplayFeed.prefix.count))
            let type = switch message.arguments.first { case .int?: "i"; case .float?: "f"; default: "s" }
            #expect(adr.contains("| `\(name)` | `\(type)` |"), "\(name)")
        }
    }

    @Test("The file's prefix is the feed's, and it has a loaded deck, an empty one and non-ASCII text")
    func fileShape() {
        #expect(Self.file["prefix"] as? String == DisplayFeed.prefix)
        let names = Self.cases.map { $0["name"] as! String }
        #expect(names.count >= 3)
        #expect(Self.cases.contains { (($0["state"] as! [String: Any])["title"] as? String ?? "").isEmpty })
        #expect(Self.cases.contains { (($0["state"] as! [String: Any])["title"] as? String ?? "").utf8.count
            > (($0["state"] as! [String: Any])["title"] as? String ?? "").count })
    }

    @Test("A case with bundle_hex gives the exact bytes of its snapshot's bundle, for the panel core's parser to read the same (#636)")
    func bundleBytes() {
        let withHex = Self.cases.filter { $0["bundle_hex"] != nil }
        #expect(!withHex.isEmpty)
        for example in withHex {
            let messages = (example["messages"] as! [[String: Any]]).compactMap(Self.message)
            let hex = OSCPacket.bundle(messages).map { String(format: "%02x", $0) }.joined()
            #expect(hex == example["bundle_hex"] as? String, "\(example["name"] as! String)")
        }
    }

    @Test("Each case: turned on with that deck in front, the feed sends exactly its messages, in order, each with one value under the prefix")
    func everyCaseSends() {
        for example in Self.cases {
            let name = example["name"] as! String
            let expected = (example["messages"] as! [[String: Any]]).map(Self.message)
            #expect(!expected.contains(nil), "\(name): a type that isn't i, f or s")
            let sender = Rig.FakeOSC(), feed = DisplayFeed()
            feed.attach(sender)
            feed.set(DisplayFeedSettings(enabled: true, host: "192.168.1.40", port: 9100))
            feed.resend(at: 0)
            feed.update(Self.deck(example["state"] as! [String: Any]))
            #expect(sender.sent == expected.compactMap { $0 }, "\(name)")
            // Since #636 the snapshot is one bundle: the case's messages, in order, in one datagram.
            #expect(sender.bundles == [expected.compactMap { $0 }], "\(name)")
            #expect(sender.sent.allSatisfy { $0.address.hasPrefix(DisplayFeed.prefix) && $0.arguments.count == 1 }, "\(name)")
        }
    }
}
