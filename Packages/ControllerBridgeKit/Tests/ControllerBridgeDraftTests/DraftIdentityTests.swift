import ControllerBridgeCapture
@testable import ControllerBridgeDraft
import Testing

/// A capture with the given ports, where only `used` input ports carry a press.
func capture(device: String, inputs: [String], used: Set<Int> = [0], steps: [CaptureStep]? = nil) -> CaptureFile {
    let press = CaptureStep(prompt: "deck1.play", status: .confirmed,
                            messages: used.sorted().map { CaptureMessage(t: 0, port: $0, bytes: [0x90, 0x01, 0x7F]) })
    return CaptureFile(appVersion: "test", device: device, ports: CapturePorts(input: inputs, output: inputs),
                       prompts: CapturePrompts.djController, steps: steps ?? [press])
}

/// Slice 1 (#189): who the profile is for, from the device and its ports.
@Suite("Draft identity")
struct DraftIdentityTests {
    @Test("Name and hint from the device; id a slug of it; a port that carried no control is excluded")
    func identity() throws {
        let draft = ProfileDraft.make(capture: capture(device: "LC6000 PRIME", inputs: ["LC6000 PRIME Controller", "LC6000 PRIME WD"]))
        #expect(draft.profile["id"] == .string("lc6000-prime"))
        #expect(draft.profile["name"] == .string("LC6000 PRIME"))
        #expect(draft.profile["device_hints"] == .array([.string("LC6000 PRIME")]))
        #expect(draft.profile["exclude_hints"] == .array([.string("LC6000 PRIME WD")]))
        #expect(draft.profile["mapping"]?["midi"]?["input"] == .string("LC6000 PRIME"))
        #expect(draft.profile["mapping"]?["midi"]?["output"] == .string("LC6000 PRIME"))
    }

    @Test("One port: nothing to exclude; punctuation and case fold into the slug")
    func onePort() throws {
        let draft = ProfileDraft.make(capture: capture(device: "DDJ-400 (Pioneer)", inputs: ["DDJ-400"]))
        #expect(draft.profile["id"] == .string("ddj-400-pioneer"))
        #expect(draft.profile["exclude_hints"] == .array([]))
    }
}
