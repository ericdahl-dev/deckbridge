import ControllerBridgeCapture
import ControllerBridgeCore
import Foundation
@testable import ControllerBridgeDraft
import Testing

/// A draft is a profile file a person finishes (#310): it loads with ControllerProfile(decoding:) as written. Every
/// key decoding needs that neither the capture nor the docs gave is a placeholder from the LC6000's mapping, listed
/// in the report, never passed off as known.
@Suite("Draft decodes as a profile")
struct DraftDecodesTests {
    @Test("The LC6000 demo draft decodes, its captured values intact")
    func lc6000() throws {
        let draft = ProfileDraft.make(capture: try #require(DraftLC6000Tests.walked()))
        let profile = try ControllerProfile(decoding: Data(draft.file.text().utf8))
        #expect(profile.mapping.notes.buttons["play"] == 1)
        #expect(profile.mapping.notes.pads == Array(32...39))
    }

    @Test("A DDJ-like draft decodes: with no needle step, the needle section is left out, not an LC6000 placeholder (#341)")
    func ddj() throws {
        let draft = ProfileDraft.make(capture: DraftCheckTests.ddj)
        #expect(draft.problems == [])
        let profile = try ControllerProfile(decoding: Data(draft.file.text().utf8))
        #expect(profile.mapping.needle == nil)
        #expect(profile.mapping.notes.buttons["play"] == 11)
        #expect(!draft.placeholders.contains { $0.key.hasPrefix("mapping.needle.") })
        #expect(draft.todos.contains { $0.key == "mapping.needle" })
    }

    @Test("A draft never takes the LC6000's color message: it would send Denon's SysEx to another controller (#530)")
    func noColorMessage() throws {
        let draft = ProfileDraft.make(capture: DraftCheckTests.ddj)
        let profile = try ControllerProfile(decoding: Data(draft.file.text().utf8))
        #expect(profile.mapping.leds.colorMessage == nil)
        #expect(!draft.placeholders.contains { $0.key.hasPrefix("mapping.leds.color_message") })
        #expect(!draft.todos.contains { $0.key.hasPrefix("mapping.leds.color_message") })
    }

    @Test("Each placeholder is listed with the LC6000 value it holds, and its TODO stays")
    func placeholders() throws {
        let draft = ProfileDraft.make(capture: DraftCheckTests.ddj)
        #expect(draft.placeholders.contains { $0.key == "mapping.leds.ring" })
        #expect(draft.todos.contains { $0.key == "mapping.leds.ring" })
        #expect(!draft.placeholders.contains { $0.key.hasPrefix("mapping.notes.") })
    }
}

/// The draft's check runs the decoder too (#310): shape rules it throws (such as a cycling pad mode with no cycle
/// button) show in the report like the import check's problems.
@Suite("Draft check includes the decoder's rules")
struct DraftShapeProblemTests {
    @Test("Docs say the pad mode cycles, but there's no mode_cycle button: the decoder's words")
    func cycle() throws {
        let docs = try DocsFacts(json: Data(#"{ "mapping": { "pads": { "mode_select": "cycle" } } }"#.utf8))
        let draft = ProfileDraft.make(capture: try #require(DraftLC6000Tests.walked()), docs: docs)
        #expect(draft.problems == ["pads: mode_select is cycle, but notes has no mode_cycle button"])
    }
}

/// Controller-specific keys the capture can't show are TODOs, never quiet LC6000 values (#310): the roll sizes, and
/// whether the jog and the needle need a touch. They're placeholders so the file loads, and listed.
@Suite("Draft TODOs for controller-specific keys")
struct DraftControllerKeyTodoTests {
    @Test("roll_sizes, jog.require_touch and needle.require_touch are TODOs with placeholders", arguments: [
        "mapping.pads.roll_sizes", "mapping.jog.require_touch", "mapping.needle.require_touch",
    ])
    func todo(_ key: String) throws {
        // The LC6000 demo capture has a jog and a needle step but nothing on these (a DDJ has no needle at all, #341).
        let draft = ProfileDraft.make(capture: try #require(DraftLC6000Tests.walked()))
        #expect(draft.todos.contains { $0.key == key })
        #expect(draft.placeholders.contains { $0.key == key })
    }

    @Test("The mixer TODO says what to note, now that mapping.mixer exists (#207, #313)")
    func mixer() {
        let draft = ProfileDraft.make(capture: DraftCheckTests.ddj)
        #expect(draft.todos.first { $0.key == "mapping.mixer" }?.how
            == "Mixer controls (mapping.mixer, #207) aren't captured yet. Note the faders, EQ, filter, cue/mute/solo and VU meter from the MIDI chart.")
    }
}
