import ControllerBridgeCapture
import Foundation
@testable import ControllerBridgeDraft
import Testing

/// Slice 8 (#189): a docs facts file (a partial profile, with a source per key) fills what the capture didn't see.
/// The capture wins where both say something; every disagreement is listed. What neither knows stays a TODO.
@Suite("Draft docs merge")
struct DraftDocsTests {
    static let file = capture(device: "DDJ-400", inputs: ["DDJ-400"], steps: [
        pressed("deck1.play", note: 11), pressed("deck1.cue", note: 12), CaptureStep(prompt: "deck1.sync", status: .skipped),
    ])

    static func docs(_ json: String) throws -> DocsFacts { try DocsFacts(json: Data(json.utf8)) }

    @Test("A key the capture skipped comes from the docs, with its source, and its TODO is gone")
    func fills() throws {
        let draft = ProfileDraft.make(capture: Self.file, docs: try Self.docs(
            #"{ "mapping": { "notes": { "sync": 88 } }, "sources": { "mapping.notes.sync": "FLX4 MIDI list p.1" } }"#))
        #expect(draft.profile.value(at: "mapping.notes.sync") == .int(88))
        #expect(!draft.todos.contains { $0.key == "mapping.notes.sync" })
        #expect(draft.fromDocs == [.init(key: "mapping.notes.sync", value: .int(88), source: "FLX4 MIDI list p.1")])
    }

    @Test("The capture wins a disagreement, and it's listed with both values and the docs' source")
    func conflict() throws {
        let draft = ProfileDraft.make(capture: Self.file, docs: try Self.docs(
            #"{ "mapping": { "notes": { "play": 10, "cue": 12 } }, "sources": { "mapping.notes.play": "Mixxx XML L100" } }"#))
        #expect(draft.profile.value(at: "mapping.notes.play") == .int(11))
        #expect(draft.conflicts == [.init(key: "mapping.notes.play", capture: .int(11), docs: .int(10), source: "Mixxx XML L100")])
    }

    @Test("Buttons and LEDs neither knows are TODOs; the mixer is one TODO for #207")
    func unknowns() {
        let draft = ProfileDraft.make(capture: Self.file)
        #expect(draft.todos.contains { $0.key == "mapping.notes.key_lock" })
        #expect(draft.todos.contains { $0.key == "mapping.leds.ring" })
        #expect(draft.todos.contains { $0.key == "mapping.mixer" && $0.how.contains("#207") })
        #expect(!draft.todos.contains { $0.key == "mapping.osc.port" })
    }

    @Test("A docs file that isn't a JSON object is refused in plain words")
    func bad() {
        #expect(throws: DocsFacts.Invalid.self) { try Self.docs("[1, 2]") }
    }
}
