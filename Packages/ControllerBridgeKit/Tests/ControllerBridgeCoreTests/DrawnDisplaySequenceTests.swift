@testable import ControllerBridgeCore
import Testing

/// The sequence rules as data (#569): the cases in vectors/messages.json, walked by the Swift decoder. The chip's C
/// walks the same cases in make test. The clock is the cases' own times, in ms.
@Suite("Drawn display: the shared sequence cases")
struct DrawnDisplaySequenceTests {
    static var cases: [[String: Any]] {
        (DrawnDisplayVectorsTests.file["sequences"] as! [String: Any])["cases"] as! [[String: Any]]
    }

    static func bytes(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }

    @Test("Every case's expected state, after its steps", arguments: cases.indices)
    func walk(index: Int) {
        let entry = Self.cases[index]
        let name = entry["name"] as! String
        var state = DrawnDisplayState()
        var now = 0
        for step in entry["steps"] as! [[String: Any]] {
            now = step["at_ms"] as! Int
            if let hex = step["send"] as? String { state.apply(Self.bytes(hex), atMs: now) }
            state.tick(atMs: now)
        }
        let expect = entry["expect"] as! [String: Any]
        for (key, value) in expect {
            switch key {
            case "drawn": #expect(state.drawn == value as? Bool, "\(name): drawn")
            case "deck": #expect((state.deck?.number ?? 0) == value as? Int, "\(name): deck")
            case "flags": #expect(Int(state.flags.rawValue) == value as? Int, "\(name): flags")
            case "stale": #expect(state.stale == value as? Bool, "\(name): stale")
            case "beat": #expect(state.beat == value as? Int, "\(name): beat")
            case "needle": #expect(state.needle == value as? Int, "\(name): needle")
            case "tempo": #expect(state.tempo == value as? Int, "\(name): tempo")
            case "phase": #expect(state.phase == value as? Int, "\(name): phase")
            case "time":
                let pair = value as? [Int]
                #expect(state.time.map { [$0.elapsed, $0.length] } == pair, "\(name): time")
            case "text_heard": #expect(state.textHeard == value as? Bool, "\(name): text_heard")
            case "look": #expect("\(state.look(atMs: now))" == value as? String, "\(name): look")
            default: Issue.record("\(name): an expectation the walker doesn't know: \(key)")
            }
        }
    }
}
