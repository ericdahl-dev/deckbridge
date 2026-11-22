import ControllerBridgeCapture
@testable import ControllerBridgeDraft
import Testing

/// Slice 5 (#189): the jog wheel, from its touch-and-turn and edge-spin steps.
@Suite("Draft jog")
struct DraftJogTests {
    static func draft(_ steps: [CaptureStep]) -> ProfileDraft {
        ProfileDraft.make(capture: capture(device: "X", inputs: ["X"], steps: [pressed("deck1.play", note: 1)] + steps))
    }

    @Test("The LC6000's absolute pair, the same on the edge: msb/lsb, the touch note, no relative keys")
    func absolute() {
        let draft = Self.draft([
            step("deck1.jog.touch", [held(40), cc(17, lsb: 49, first: 8000, last: 8000)]),
            step("deck1.jog.edge", [cc(17, lsb: 49, first: 8000, last: 8200)]),
        ])
        #expect(draft.profile.value(at: "mapping.jog.msb_cc") == .int(17))
        #expect(draft.profile.value(at: "mapping.jog.lsb_cc") == .int(49))
        #expect(draft.profile.value(at: "mapping.jog.relative_cc") == nil)
        #expect(draft.profile.value(at: "mapping.notes.platter_touch") == .int(40))
    }

    @Test("A DDJ-style relative jog: the top's CC, the edge's own CC, offset-64, the touch note")
    func relative() {
        let draft = Self.draft([
            step("deck1.jog.touch", [held(54), cc(34, encoding: .offset64, first: 0x41, last: 0x3F)]),
            step("deck1.jog.edge", [cc(33, encoding: .offset64, first: 0x41, last: 0x3F)]),
        ])
        #expect(draft.profile.value(at: "mapping.jog.relative_cc") == .int(34))
        #expect(draft.profile.value(at: "mapping.jog.relative_edge_cc") == .int(33))
        #expect(draft.profile.value(at: "mapping.jog.msb_cc") == nil)
        #expect(draft.profile.value(at: "mapping.midi.encoder_format") == .string("offset_64"))
        #expect(draft.profile.value(at: "mapping.notes.platter_touch") == .int(54))
    }

    @Test("Counts per turn are always a TODO: a capture turn isn't a measured full turn")
    func countsPerRev() {
        let draft = Self.draft([step("deck1.jog.touch", [held(40), cc(17, lsb: 49, first: 8000, last: 8000)])])
        #expect(draft.todos.contains { $0.key == "mapping.jog.counts_per_rev" })
    }

    @Test("A 7-bit absolute jog is a TODO; no touch note is a TODO for require_touch")
    func odd() {
        let draft = Self.draft([step("deck1.jog.touch", [cc(17, first: 10, last: 20)])])
        #expect(draft.profile.value(at: "mapping.jog.msb_cc") == nil)
        #expect(draft.todos.contains { $0.key == "mapping.jog" })
        #expect(draft.todos.contains { $0.key == "mapping.notes.platter_touch" })
    }
}
