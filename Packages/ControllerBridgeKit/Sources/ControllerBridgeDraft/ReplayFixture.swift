import ControllerBridgeCapture
import Foundation

/// A capture's traffic as a replay fixture (#189), so a new profile has tests from day one: each confirmed step's MIDI
/// in order, and for the steps whose result is certain, the OSC Syndicate should get (the address under the OSC root,
/// then its arguments). A Coordinator-seam test replays it against the bundled profile named `profile`.
public enum ReplayFixture {
    public static func make(capture: CaptureFile, profile: String) -> DraftJSON {
        let steps = capture.steps.filter { $0.status == .confirmed && !$0.messages.isEmpty }.map { step -> DraftJSON in
            var pairs: [DraftJSON.Pair] = [
                .init(key: "prompt", value: .string(step.prompt)),
                .init(key: "midi", value: .array(step.messages.map { .string(hex($0.bytes)) })),
            ]
            if let expected = expect(step.prompt) { pairs.append(.init(key: "expect", value: .array(expected.map(DraftJSON.string)))) }
            return .object(pairs)
        }
        return .object([
            .init(key: "profile", value: .string(profile)),
            .init(key: "device", value: .string(capture.device)),
            .init(key: "steps", value: .array(steps)),
        ])
    }

    /// What a step sends Syndicate, for the prompts whose result doesn't depend on Syndicate's state.
    static func expect(_ prompt: String) -> [String]? {
        let presses: [String: String] = [
            "deck1.play": "Deck/1/PlayPause", "deck1.sync": "Deck/1/TempoSync", "deck1.loop_in": "Deck/1/LoopIn",
            "deck1.loop_out": "Deck/1/LoopOut", "deck1.auto_loop": "Deck/1/Loop", "deck2.play": "Deck/2/PlayPause",
        ]
        if let address = presses[prompt] { return ["\(address) 1"] }
        if prompt == "deck1.cue" { return ["Deck/1/Cue 1", "Deck/1/Cue 0"] }
        if prompt.hasPrefix("deck1.hotcue"), !prompt.hasSuffix(".shift"), let pad = Int(prompt.dropFirst("deck1.hotcue".count)) {
            return ["Deck/1/HotCue \(pad) 1", "Deck/1/HotCue \(pad) 0"]
        }
        return nil
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
