import ControllerBridgeCapture
@testable import ControllerBridgeDraft
import Testing

/// A confirmed press step whose control is note `note` on `channel`.
func pressed(_ prompt: String, note: Int, channel: Int = 1) -> CaptureStep {
    CaptureStep(prompt: prompt, status: .confirmed,
                messages: [CaptureMessage(t: 0, bytes: [UInt8(0x90 + channel - 1), UInt8(note), 0x7F])],
                controls: [ControlFacts(kind: .note, channel: channel, number: note, release: .noteOff, first: 127, last: 127, min: 127, max: 127)])
}

/// Slice 2 (#189): each button step becomes its note, the channel comes from Play, and noise notes are ignored.
@Suite("Draft buttons")
struct DraftButtonTests {
    static let steps = [
        pressed("deck1.play", note: 11), pressed("deck1.cue", note: 12), pressed("deck1.sync", note: 88),
        pressed("deck1.loop_in", note: 16), pressed("deck1.loop_out", note: 17), pressed("deck1.auto_loop", note: 20),
        pressed("deck1.browse.press", note: 65), pressed("deck1.shift", note: 63),
    ]

    @Test("Each button's note, under the profile's names; the channel is Play's")
    func buttons() {
        let draft = ProfileDraft.make(capture: capture(device: "DDJ-400", inputs: ["DDJ-400"], steps: Self.steps))
        let notes = draft.profile.value(at: "mapping.notes")
        #expect([notes?["play"], notes?["cue"], notes?["sync"], notes?["loop_in"], notes?["loop_out"], notes?["auto_loop"],
                 notes?["select_press"], notes?["shift"]] == [11, 12, 88, 16, 17, 20, 65, 63].map { .int($0) })
        #expect(draft.profile.value(at: "mapping.midi.channel") == .int(1))
    }

    @Test("A skipped step, or one with no control, is a TODO, not a note")
    func skipped() {
        var steps = Self.steps
        steps[1] = CaptureStep(prompt: "deck1.cue", status: .skipped)
        steps[2] = CaptureStep(prompt: "deck1.sync", status: .confirmed)
        let draft = ProfileDraft.make(capture: capture(device: "DDJ-400", inputs: ["DDJ-400"], steps: steps))
        #expect(draft.profile.value(at: "mapping.notes.cue") == nil)
        #expect(draft.profile.value(at: "mapping.notes.sync") == nil)
        #expect(draft.todos.contains { $0.key == "mapping.notes.cue" && $0.how.contains("skipped") })
        #expect(draft.todos.contains { $0.key == "mapping.notes.sync" && $0.how.contains("no control") })
    }

    @Test("A button that sends a CC is a TODO: profiles take buttons as notes")
    func ccButton() {
        var steps = Self.steps
        steps[0] = CaptureStep(prompt: "deck1.play", status: .confirmed,
                               controls: [ControlFacts(kind: .cc, channel: 1, number: 30, encoding: .absolute, first: 127, last: 0, min: 0, max: 127)])
        let draft = ProfileDraft.make(capture: capture(device: "X", inputs: ["X"], steps: steps))
        #expect(draft.profile.value(at: "mapping.notes.play") == nil)
        #expect(draft.todos.contains { $0.key == "mapping.notes.play" && $0.how.contains("CC 30") })
    }

    @Test("Note noise (the LC6000's note 52 heartbeat) is ignored; CC and clock noise isn't a note")
    func noise() {
        var file = capture(device: "LC6000 PRIME", inputs: ["LC6000 PRIME"], steps: Self.steps)
        file.noise = [[0x90, 0x34], [0xB0, 0x10], [0xF8]]
        let draft = ProfileDraft.make(capture: file)
        #expect(draft.profile.value(at: "mapping.midi.ignore_notes") == .array([.int(52)]))
    }
}
