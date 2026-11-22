import Foundation
@testable import ControllerBridgeCore
import Testing

/// The Kit README's key list (#382) is the key table's: same keys, and no stale key named elsewhere in it.
@Suite("Profile key table: the README")
struct ProfileKeysReadmeTests {
    static let readme = try! String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("README.md"), encoding: .utf8)

    /// The keys in the README's "Mapping keys" section: each list line starts with the key in backticks.
    static var listed: [String] {
        guard let start = readme.range(of: "\n## Mapping keys\n") else { return [] }
        let section = readme[start.upperBound...].prefix { _ in true }
        let body = section.components(separatedBy: "\n## ").first ?? ""
        return body.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("- `"), let end = line.dropFirst(3).firstIndex(of: "`") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 3)..<end])
        }
    }

    @Test("The README's Mapping keys section lists every key in the table, in its order, and nothing else")
    func listMatchesTable() {
        #expect(Self.listed == ProfileKeys.all.map(\.path))
    }

    @Test("Every mapping key the README names in backticks is a key in the table")
    func noStaleKeys() throws {
        let sections = ["midi", "osc", "deck", "jog", "pitch", "needle", "browse", "notes", "leds", "pads", "mixer"]
        let pattern = try Regex(#"`((?:"# + sections.joined(separator: "|") + #")(?:\.[a-z_]+|\[\])+)`"#)
        let named = Set(Self.readme.matches(of: pattern).map { String($0.output[1].substring!) })
        #expect(named.filter { ProfileKeys.key($0) == nil }.sorted() == [])
    }
}
