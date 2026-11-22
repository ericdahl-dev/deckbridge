import Foundation
@testable import ControllerBridgeDraft
import Testing

/// The DDJ-400 and DDJ-FLX4 facts files (#280), in docs/research/ddj: each drafts, from the docs alone, a profile that
/// passes the profile check, with a source for every key it sets.
@Suite("Pioneer facts files")
struct DraftPioneerFactsTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/research/ddj")

    static func draft(_ file: String, device: String) throws -> (ProfileDraft, DocsFacts) {
        let docs = try DocsFacts(json: Data(contentsOf: directory.appendingPathComponent(file)))
        return (ProfileDraft.make(device: device, docs: docs), docs)
    }

    @Test("Each facts file drafts a profile with no import problems", arguments: [
        ("ddj-400.facts.json", "DDJ-400"), ("ddj-flx4.facts.json", "DDJ-FLX4"),
    ])
    func passesTheCheck(file: String, device: String) throws {
        let (draft, _) = try Self.draft(file, device: device)
        #expect(draft.problems == [])
    }

    @Test("Every fact has a source", arguments: ["ddj-400.facts.json", "ddj-flx4.facts.json"])
    func everyFactSourced(file: String) throws {
        let docs = try DocsFacts(json: Data(contentsOf: Self.directory.appendingPathComponent(file)))
        #expect(!docs.facts.isEmpty)
        #expect(docs.facts.map(\.key).filter { docs.sources[$0] == nil } == [])
    }

    @Test("The two differ where the sources say: Shift+Play is 0x47 on the DDJ-400 (Mixxx), 0x0E on the FLX4 (its list)")
    func shiftPlay() throws {
        let (ddj400, _) = try Self.draft("ddj-400.facts.json", device: "DDJ-400")
        let (flx4, _) = try Self.draft("ddj-flx4.facts.json", device: "DDJ-FLX4")
        #expect(ddj400.profile.value(at: "mapping.notes.shifted.play") == .int(0x47))
        #expect(flx4.profile.value(at: "mapping.notes.shifted.play") == .int(0x0E))
    }
}
