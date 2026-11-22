import ControllerBridgeCapture
@testable import ControllerBridgeDraft
import Testing

func step(_ prompt: String, _ controls: [ControlFacts]) -> CaptureStep {
    CaptureStep(prompt: prompt, status: .confirmed, messages: [CaptureMessage(t: 0, bytes: [0xB0, 0, 0])], controls: controls)
}

func cc(_ number: Int, lsb: Int? = nil, channel: Int = 1, encoding: ControlEncoding? = .absolute, first: Int, last: Int) -> ControlFacts {
    ControlFacts(kind: .cc, channel: channel, number: number, lsb: lsb, encoding: encoding, first: first, last: last,
                 min: min(first, last), max: max(first, last))
}

func held(_ note: Int) -> ControlFacts {
    ControlFacts(kind: .note, channel: 1, number: note, release: .noteOff, first: 127, last: 127, min: 127, max: 127)
}

/// Slice 4 (#189): the pitch fader, the needle strip and the browse knob.
@Suite("Draft faders and knobs")
struct DraftContinuousTests {
    static func draft(_ steps: [CaptureStep]) -> ProfileDraft {
        ProfileDraft.make(capture: capture(device: "X", inputs: ["X"], steps: [pressed("deck1.play", note: 1)] + steps))
    }

    @Test("A 14-bit pitch fader, 0 at the top (the LC6000): its pair, 14 bits, not inverted")
    func pitch14() {
        let draft = Self.draft([step("deck1.pitch", [cc(8, lsb: 40, first: 0, last: 16383)])])
        #expect(draft.profile.value(at: "mapping.pitch") == .object([
            .init(key: "bits", value: .int(14)), .init(key: "msb_cc", value: .int(8)), .init(key: "lsb_cc", value: .int(40)),
            .init(key: "invert", value: .bool(false)),
        ]))
    }

    @Test("A 7-bit pitch fader at its maximum at the top: 7 bits, no LSB, inverted")
    func pitch7() {
        let draft = Self.draft([step("deck1.pitch", [cc(9, first: 127, last: 0)])])
        #expect(draft.profile.value(at: "mapping.pitch.bits") == .int(7))
        #expect(draft.profile.value(at: "mapping.pitch.lsb_cc") == nil)
        #expect(draft.profile.value(at: "mapping.pitch.invert") == .bool(true))
    }

    @Test("A pitch fader on pitch bend is a TODO (dropped from v1.2, #199)")
    func pitchBend() {
        let bend = ControlFacts(kind: .pitchBend, channel: 1, first: 0, last: 16383, min: 0, max: 16383)
        let draft = Self.draft([step("deck1.pitch", [bend])])
        #expect(draft.profile.value(at: "mapping.pitch") == nil)
        #expect(draft.todos.contains { $0.key == "mapping.pitch" && $0.how.contains("#199") })
    }

    @Test("The needle strip: its pair and the note held while touching it")
    func needle() {
        let draft = Self.draft([step("deck1.needle", [held(70), cc(64, lsb: 65, first: 1000, last: 15000)])])
        #expect(draft.profile.value(at: "mapping.needle") == .object([
            .init(key: "msb_cc", value: .int(64)), .init(key: "lsb_cc", value: .int(65)), .init(key: "touch_note", value: .int(70)),
        ]))
    }

    @Test("The browse knob: its CC and the encoder format; a format the turn couldn't tell is a TODO")
    func browse() {
        let known = Self.draft([step("deck1.browse.turn", [cc(64, encoding: .offset64, first: 0x41, last: 0x3F)])])
        #expect(known.profile.value(at: "mapping.browse.select_turn_cc") == .int(64))
        #expect(known.profile.value(at: "mapping.midi.encoder_format") == .string("offset_64"))
        let unknown = Self.draft([step("deck1.browse.turn", [cc(6, encoding: nil, first: 1, last: 1)])])
        #expect(unknown.profile.value(at: "mapping.browse.select_turn_cc") == .int(6))
        #expect(unknown.profile.value(at: "mapping.midi.encoder_format") == nil)
        #expect(unknown.todos.contains { $0.key == "mapping.midi.encoder_format" })
    }
}
