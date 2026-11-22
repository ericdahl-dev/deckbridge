import ControllerBridgeCapture
@testable import ControllerBridgeDraft
import Testing

/// Slice 6 (#189): the deck layers, from switching the left side to deck 2 and pressing its Play.
@Suite("Draft layers")
struct DraftLayerTests {
    static func layer(_ ch: [Int]) -> [ControlFacts] {
        ch.map { ControlFacts(kind: .note, channel: $0, number: 51, release: .noteOnZero, first: 127, last: 127, min: 127, max: 127) }
    }

    @Test("The LC6000: the layer note on deck 2's channel, Play on channel 2: layers for decks 1 and 2, layer_note 51")
    func lc6000() {
        let draft = ProfileDraft.make(capture: capture(device: "X", inputs: ["X"], steps: [
            pressed("deck1.play", note: 1), step("layer2.select", Self.layer([2])), pressed("deck2.play", note: 1, channel: 2),
        ]))
        #expect(draft.profile.value(at: "mapping.midi.layers") == .array([
            .object([.init(key: "channel", value: .int(1)), .init(key: "deck", value: .int(1))]),
            .object([.init(key: "channel", value: .int(2)), .init(key: "deck", value: .int(2))]),
        ]))
        #expect(draft.profile.value(at: "mapping.midi.layer_note") == .int(51))
        #expect(draft.todos.contains { $0.key == "mapping.midi.layers" && $0.how.contains("decks 3 and 4") })
    }

    @Test("Deck 2's Play on deck 1's channel: no layers to draft, a TODO")
    func sameChannel() {
        let draft = ProfileDraft.make(capture: capture(device: "X", inputs: ["X"], steps: [
            pressed("deck1.play", note: 1), step("layer2.select", Self.layer([1])), pressed("deck2.play", note: 1, channel: 1),
        ]))
        #expect(draft.profile.value(at: "mapping.midi.layers") == nil)
        #expect(draft.profile.value(at: "mapping.midi.layer_note") == nil)
        #expect(draft.todos.contains { $0.key == "mapping.midi.layers" })
    }

    @Test("A layer button on another note than the one deck 2 announces: no layer_note, a TODO")
    func noAnnounce() {
        let draft = ProfileDraft.make(capture: capture(device: "X", inputs: ["X"], steps: [
            pressed("deck1.play", note: 1), step("layer2.select", Self.layer([1])), pressed("deck2.play", note: 1, channel: 2),
        ]))
        #expect(draft.profile.value(at: "mapping.midi.layers") != nil)
        #expect(draft.profile.value(at: "mapping.midi.layer_note") == nil)
        #expect(draft.todos.contains { $0.key == "mapping.midi.layer_note" })
    }
}
