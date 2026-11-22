import ControllerBridgeCapture
import ControllerBridgeCore
import Foundation
@testable import ControllerBridgeDraft
import Testing

/// Slice 9 (#189): the draft's mapping passes the profile import check as written, and its file is JSON a profile
/// reader takes.
@Suite("Draft passes the import check")
struct DraftCheckTests {
    /// A DDJ-400-like capture: buttons on channel 1, pads on 8, a relative offset-64 jog with an edge, a 14-bit pitch,
    /// a browse knob, deck 2 on channel 2, and Shift in hardware.
    static let ddj = capture(device: "DDJ-400", inputs: ["DDJ-400"], steps: [
        pressed("deck1.play", note: 11), pressed("deck1.cue", note: 12), pressed("deck1.sync", note: 88),
        pressed("deck1.loop_in", note: 16), pressed("deck1.loop_out", note: 17), pressed("deck1.auto_loop", note: 20),
        pressed("deck1.browse.press", note: 65), pressed("deck1.shift", note: 63),
    ] + (0...7).map { pressed("deck1.hotcue\($0 + 1)", note: $0, channel: 8) } + [
        step("deck1.pitch", [cc(0, lsb: 32, first: 16383, last: 0)]),
        step("deck1.jog.touch", [held(54), cc(34, encoding: .offset64, first: 0x41, last: 0x3F)]),
        step("deck1.jog.edge", [cc(33, encoding: .offset64, first: 0x41, last: 0x3F)]),
        step("deck1.browse.turn", [cc(64, encoding: .offset64, first: 0x41, last: 0x3F)]),
        step("layer2.select", []), pressed("deck2.play", note: 11, channel: 2),
        pressed("deck1.play.shift", note: 71),
    ])

    @Test("The mapping has no import problems; the file parses as JSON with the profile's header")
    func passes() throws {
        let draft = ProfileDraft.make(capture: Self.ddj)
        let text = draft.profile.text()
        let file = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(file?["id"] as? String == "ddj-400")
        let mapping = try JSONSerialization.data(withJSONObject: file?["mapping"] ?? [:])
        #expect(Mapping.problems(in: mapping, whole: true) == [])
        // The file with its placeholders, and no needle section: a DDJ has no strip (#341).
        #expect(draft.problems == [])
    }

    @Test("A draft whose docs set a bad value carries the check's own problem, by key")
    func badDocs() throws {
        let docs = try DocsFacts(json: Data(#"{ "mapping": { "notes": { "key_lock": 300 } } }"#.utf8))
        let draft = ProfileDraft.make(capture: Self.ddj, docs: docs)
        #expect(draft.problems == ["notes.key_lock: 300 is out of range, expected 0-127"])
    }
}
