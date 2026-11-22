import ControllerBridgeCapture
import Foundation
@testable import ControllerBridgeDraft
import Testing

/// Slice 12 (#189): the report a person reviews next to the draft: the import check's problems, the disagreements,
/// what came from the docs, and every TODO with how to get it.
@Suite("Draft report")
struct DraftReportTests {
    @Test("Problems, conflicts, docs and TODOs, each under its heading, in Markdown")
    func report() throws {
        let file = capture(device: "DDJ-400", inputs: ["DDJ-400"], steps: [
            pressed("deck1.play", note: 11), CaptureStep(prompt: "deck1.cue", status: .skipped),
        ])
        let docs = try DocsFacts(json: Data(#"{ "mapping": { "notes": { "play": 10, "sync": 88 } }, "sources": { "mapping.notes.play": "Mixxx XML L10", "mapping.notes.sync": "FLX4 list p.1" } }"#.utf8))
        let text = DraftReport.text(ProfileDraft.make(capture: file, docs: docs))
        #expect(text.hasPrefix("# Draft profile: DDJ-400 (ddj-400)\n"))
        #expect(text.contains("## Capture and docs disagree\n\n- `mapping.notes.play`: the capture says 11, the docs say 10 (Mixxx XML L10). Kept 11.\n"))
        #expect(text.contains("## From the docs\n\n- `mapping.notes.sync` = 88 (FLX4 list p.1)\n"))
        #expect(text.contains("- [ ] `mapping.notes.cue`: The owner skipped \"deck1.cue\"."))
        #expect(!text.contains("## Import check"))
    }
}

/// The report lists every placeholder (#310), so nothing filled from the LC6000 passes for known.
@Suite("Draft report placeholders")
struct DraftReportPlaceholderTests {
    @Test("A placeholder section names each key and the LC6000 value it holds")
    func listed() {
        let text = DraftReport.text(ProfileDraft.make(capture: DraftCheckTests.ddj))
        #expect(text.contains("## Placeholders from the LC6000 (check each)\n"))
        #expect(text.contains("- `mapping.leds.ring` = 40\n"))
        #expect(text.contains("- `mapping.osc.port` = 9090\n"))
        // No needle step on a DDJ: the section is left out, not a placeholder (#341).
        #expect(!text.contains("- `mapping.needle.msb_cc` ="))
    }
}
