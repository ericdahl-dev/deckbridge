import ControllerBridgeCapture
@testable import ControllerBridgeDraft
import Testing

/// Slice 3 (#189): hot cue pads 1–8 become notes.pads; pads on their own channel set pads.channel; the per-mode notes
/// and the mode selection the capture can't see are TODOs.
@Suite("Draft pads")
struct DraftPadTests {
    static func pads(channel: Int, notes: [Int]) -> [CaptureStep] {
        [pressed("deck1.play", note: 11)] + notes.enumerated().map { pressed("deck1.hotcue\($0 + 1)", note: $1, channel: channel) }
    }

    @Test("Pads on the deck's channel: their notes in order, no pads.channel")
    func deckChannel() {
        let draft = ProfileDraft.make(capture: capture(device: "LC6000", inputs: ["LC6000"], steps: Self.pads(channel: 1, notes: Array(32...39))))
        #expect(draft.profile.value(at: "mapping.notes.pads") == .array((32...39).map(DraftJSON.int)))
        #expect(draft.profile.value(at: "mapping.pads.channel") == nil)
    }

    @Test("Pads on channel 8 (the DDJ-400's deck 1): pads.channel 8")
    func ownChannel() {
        let draft = ProfileDraft.make(capture: capture(device: "DDJ-400", inputs: ["DDJ-400"], steps: Self.pads(channel: 8, notes: Array(0...7))))
        #expect(draft.profile.value(at: "mapping.notes.pads") == .array((0...7).map(DraftJSON.int)))
        #expect(draft.profile.value(at: "mapping.pads.channel") == .int(8))
    }

    @Test("A missing pad leaves notes.pads out, a TODO naming it; pads on two channels are a TODO")
    func gaps() {
        var steps = Self.pads(channel: 1, notes: Array(32...39))
        steps[3] = CaptureStep(prompt: "deck1.hotcue3", status: .skipped)
        let missing = ProfileDraft.make(capture: capture(device: "X", inputs: ["X"], steps: steps))
        #expect(missing.profile.value(at: "mapping.notes.pads") == nil)
        #expect(missing.todos.contains { $0.key == "mapping.notes.pads" && $0.how.contains("deck1.hotcue3") })
        steps = Self.pads(channel: 1, notes: Array(32...39))
        steps[2] = pressed("deck1.hotcue2", note: 33, channel: 2)
        let split = ProfileDraft.make(capture: capture(device: "X", inputs: ["X"], steps: steps))
        #expect(split.todos.contains { $0.key == "mapping.pads.channel" })
    }

    @Test("Per-mode pad notes and the mode selection are always TODOs: the capture only records Hot Cue mode")
    func modes() {
        let draft = ProfileDraft.make(capture: capture(device: "X", inputs: ["X"], steps: Self.pads(channel: 1, notes: Array(32...39))))
        #expect(draft.todos.contains { $0.key == "mapping.pads.mode_notes" })
        #expect(draft.todos.contains { $0.key == "mapping.pads.mode_select" })
    }
}

/// The pad count is the capture's (#310, #196 allows 1–16): as many as its prompt list asks hot cues for.
@Suite("Draft pad count")
struct DraftPadCountTests {
    static func capture(pads: Int, notes: [Int]) -> CaptureFile {
        let prompts = [CapturePrompt(id: "deck1.play", text: "Play", gesture: .press)]
            + (1...pads).map { CapturePrompt(id: "deck1.hotcue\($0)", text: "Pad \($0)", gesture: .press) }
        var file = ControllerBridgeDraftTests.capture(device: "X", inputs: ["X"], steps:
            [pressed("deck1.play", note: 1)] + notes.enumerated().map { pressed("deck1.hotcue\($0 + 1)", note: $1) })
        file.prompts = prompts
        return file
    }

    @Test("Four pads asked, four captured: notes.pads has four")
    func four() {
        let draft = ProfileDraft.make(capture: Self.capture(pads: 4, notes: [10, 11, 12, 13]))
        #expect(draft.profile.value(at: "mapping.notes.pads") == .array([10, 11, 12, 13].map(DraftJSON.int)))
    }

    @Test("Sixteen pads asked, sixteen captured: notes.pads has sixteen")
    func sixteen() {
        let draft = ProfileDraft.make(capture: Self.capture(pads: 16, notes: Array(100...115)))
        #expect(draft.profile.value(at: "mapping.notes.pads") == .array((100...115).map(DraftJSON.int)))
    }

    @Test("Four asked, three captured: a TODO naming the fourth, and how many there are")
    func missing() {
        let draft = ProfileDraft.make(capture: Self.capture(pads: 4, notes: [10, 11, 12]))
        #expect(draft.profile.value(at: "mapping.notes.pads") == nil)
        #expect(draft.todos.first { $0.key == "mapping.notes.pads" }?.how.contains("deck1.hotcue4") == true)
        #expect(draft.todos.first { $0.key == "mapping.notes.pads" }?.how.contains("all 4") == true)
    }
}
