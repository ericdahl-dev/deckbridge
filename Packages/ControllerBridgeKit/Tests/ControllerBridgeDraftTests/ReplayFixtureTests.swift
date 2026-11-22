import Foundation
import ControllerBridgeCapture
@testable import ControllerBridgeDraft
import Testing

/// Slice 11 (#189): the capture's traffic as a replay fixture, so a new profile has tests from day one. Each confirmed
/// step keeps its MIDI in order; the steps whose OSC is certain say what Syndicate should get.
@Suite("Replay fixture")
struct ReplayFixtureTests {
    @Test("Steps keep their MIDI as hex; Play, Cue and a hot cue say their OSC; a skipped step is left out")
    func fixture() {
        var cue = pressed("deck1.cue", note: 2)
        cue.messages.append(CaptureMessage(t: 150, bytes: [0x80, 0x02, 0x00]))
        let file = capture(device: "LC6000", inputs: ["LC6000"], steps: [
            pressed("deck1.play", note: 1), cue, CaptureStep(prompt: "deck1.sync", status: .skipped), pressed("deck1.hotcue3", note: 34),
            step("deck1.pitch", [cc(8, lsb: 40, first: 0, last: 16383)]),
        ])
        let fixture = ReplayFixture.make(capture: file, profile: "denon-lc6000-prime")
        #expect(fixture["profile"] == .string("denon-lc6000-prime"))
        #expect(fixture["steps"] == .array([
            .object([.init(key: "prompt", value: .string("deck1.play")), .init(key: "midi", value: .array([.string("90 01 7F")])),
                     .init(key: "expect", value: .array([.string("Deck/1/PlayPause 1")]))]),
            .object([.init(key: "prompt", value: .string("deck1.cue")), .init(key: "midi", value: .array([.string("90 02 7F"), .string("80 02 00")])),
                     .init(key: "expect", value: .array([.string("Deck/1/Cue 1"), .string("Deck/1/Cue 0")]))]),
            .object([.init(key: "prompt", value: .string("deck1.hotcue3")), .init(key: "midi", value: .array([.string("90 22 7F")])),
                     .init(key: "expect", value: .array([.string("Deck/1/HotCue 3 1"), .string("Deck/1/HotCue 3 0")]))]),
            .object([.init(key: "prompt", value: .string("deck1.pitch")), .init(key: "midi", value: .array([.string("B0 00 00")]))]),
        ]))
    }
}

/// The LC6000 fixture the Core replay test runs (Tests/ControllerBridgeCoreTests/Resources/Fixtures) is this tool's
/// output for the demo capture. WRITE_FIXTURES=1 swift test rewrites it.
@Suite("LC6000 replay fixture")
struct LC6000FixtureTests {
    static let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ControllerBridgeCoreTests/Resources/Fixtures/denon-lc6000-prime.json")

    @Test("The committed fixture is the tool's output for the LC6000 demo capture")
    func pinned() throws {
        let capture = try #require(DraftLC6000Tests.walked())
        let text = ReplayFixture.make(capture: capture, profile: "denon-lc6000-prime").text() + "\n"
        if ProcessInfo.processInfo.environment["WRITE_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: Self.path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: Self.path, atomically: true, encoding: .utf8)
        }
        #expect(try String(contentsOf: Self.path, encoding: .utf8) == text)
    }
}
