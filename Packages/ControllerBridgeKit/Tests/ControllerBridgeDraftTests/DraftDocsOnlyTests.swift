import Foundation
@testable import ControllerBridgeDraft
import Testing

/// A draft from the docs alone (#280): no owner and no capture yet, as for the DDJ-400 and FLX4 from Pioneer's MIDI
/// list and Mixxx. The device name gives the identity; the docs set what they say, each with its source; everything
/// else is a TODO for the owner's capture, never a guess.
@Suite("Draft from docs only")
struct DraftDocsOnlyTests {
    static func docs(_ json: String) throws -> DocsFacts { try DocsFacts(json: Data(json.utf8)) }

    @Test("The identity comes from the device name; the docs' keys are set with their sources")
    func identityAndFacts() throws {
        let draft = ProfileDraft.make(device: "DDJ-400", docs: try Self.docs(
            #"{ "mapping": { "midi": { "channel": 1 }, "notes": { "play": 11 } }, "sources": { "mapping.notes.play": "FLX4 MIDI list p.1" } }"#))
        #expect(draft.profile.value(at: "id") == .string("ddj-400"))
        #expect(draft.profile.value(at: "name") == .string("DDJ-400"))
        #expect(draft.profile.value(at: "device_hints") == .array([.string("DDJ-400")]))
        #expect(draft.profile.value(at: "mapping.notes.play") == .int(11))
        #expect(draft.fromDocs.contains(.init(key: "mapping.notes.play", value: .int(11), source: "FLX4 MIDI list p.1")))
    }

    @Test("What the docs don't say is a TODO naming the owner's capture; none mentions a capture step that was never run")
    func todosAskForTheCapture() throws {
        let draft = ProfileDraft.make(device: "DDJ-400", docs: try Self.docs(#"{ "mapping": { "notes": { "play": 11 } } }"#))
        for key in ["mapping.pitch", "mapping.jog", "mapping.notes.pads", "mapping.midi.ignore_notes"] {
            #expect(draft.todos.first { $0.key == key }?.how.contains("owner's capture") == true, "\(key)")
        }
        #expect(!draft.todos.contains { $0.how.contains("The capture has no") || $0.how.contains("The owner skipped") })
        #expect(!draft.todos.contains { $0.key == "mapping.notes.play" })
    }

    @Test("No capture means no noise notes: ignore_notes is empty, never the LC6000's placeholder")
    func noNoise() {
        let draft = ProfileDraft.make(device: "DDJ-400", docs: DocsFacts())
        #expect(draft.file.value(at: "mapping.midi.ignore_notes") == .array([]))
    }

    @Test("Layers without a layer note keep none: the LC6000's note 51 would read as a layer switch on another controller")
    func noBorrowedLayerNote() throws {
        let draft = ProfileDraft.make(device: "DDJ-400", docs: try Self.docs(
            #"{ "mapping": { "midi": { "channel": 1, "layers": [{ "channel": 1, "deck": 1 }, { "channel": 2, "deck": 2 }] } } }"#))
        #expect(draft.file.value(at: "mapping.midi.layer_note") == nil)
        #expect(draft.problems == [])
    }

    @Test("The report says the draft is from the docs alone, not that a capture wins")
    func reportSaysDocsOnly() {
        let text = DraftReport.text(ProfileDraft.make(device: "DDJ-400", docs: DocsFacts()))
        #expect(text.contains("from the docs alone"))
        #expect(!text.contains("The capture wins"))
    }

    @Test("A mixer the docs filled has no 'not captured yet' TODO")
    func mixerFromDocs() throws {
        let draft = ProfileDraft.make(device: "DDJ-400", docs: try Self.docs(
            #"{ "mapping": { "mixer": { "cue_note": 84 } }, "sources": { "mapping.mixer.cue_note": "FLX4 list p.2" } }"#))
        #expect(!draft.todos.contains { $0.key == "mapping.mixer" })
    }
}
