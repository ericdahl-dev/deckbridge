import ControllerBridgeCapture
import ControllerBridgeCore
import Foundation
@testable import ControllerBridgeDraft
import Testing

/// Slice 10 (#189), the key proof: an LC6000 capture drafts the bundled LC6000 profile, or a listed difference.
///
/// The capture is DemoCapture walked through CaptureFlow, the app's own path: hand-built from the confirmed LC6000
/// facts, port 0 only, Shift unchanged on the wire. Replace it with #213's recording when there is one; the prompts
/// match.
@Suite("Draft of an LC6000 capture")
struct DraftLC6000Tests {
    static func walked() -> CaptureFile? {
        var flow = CaptureFlow(appVersion: "test")
        flow.start(device: DemoCapture.deviceName, ports: DemoCapture.ports, at: 0)
        var now = 0.0
        while let prompt = flow.prompt {
            for message in DemoCapture.take(for: prompt) { flow.receive(message.bytes, at: now + 1 + message.time) }
            now += 6
            flow.next(at: now)
            now += 4
        }
        return flow.file
    }

    /// The bundled mapping's leaves, by dotted key under "mapping".
    static func bundled() throws -> [String: DraftJSON] {
        let facts = try DocsFacts(json: Data(#"{"mapping": \#(String(decoding: Mapping.defaultMappingJSON(), as: UTF8.self))}"#.utf8)).facts
        return Dictionary(uniqueKeysWithValues: facts.map { ($0.key, $0.value) })
    }

    @Test("Every key the draft sets has the bundled value, except the listed differences")
    func matches() throws {
        let draft = ProfileDraft.make(capture: try #require(Self.walked()))
        let bundled = try Self.bundled()
        let set = try DocsFacts(json: Data(draft.profile.text().utf8)).facts.filter { $0.key.hasPrefix("mapping.") }
        let differ = set.filter { bundled[$0.key] != $0.value }.map(\.key).sorted()
        #expect(differ == [
            // The demo calls itself "Demo controller"; the bundled profile matches any "LC6000".
            "mapping.midi.input",
            // Only decks 1 and 2 are captured; the bundled LC6000 has 4 layers (a TODO says so).
            "mapping.midi.layers",
            "mapping.midi.output",
        ])
    }

    @Test("Every bundled key the draft leaves out is a TODO, or a general setting that inherits its default")
    func gaps() throws {
        let draft = ProfileDraft.make(capture: try #require(Self.walked()))
        let set = Set(try DocsFacts(json: Data(draft.profile.text().utf8)).facts.map(\.key))
        let todo = draft.todos.map(\.key)
        let general = ["mapping.osc.", "mapping.deck.", "mapping.pads.roll_sizes", "mapping.jog.bend_release_ms",
                       "mapping.jog.seek_seconds_per_rev", "mapping.jog.beats_per_rev", "mapping.jog.require_touch",
                       "mapping.pitch.dead_zone", "mapping.pitch.pickup", "mapping.needle.require_touch", "mapping.needle.shift_fader",
                       "mapping.leds.", "mapping.notes."]
        // Denon's color message (#530) is never drafted: it would send Denon's SysEx to another controller.
        let unexplained = try Self.bundled().keys.filter { key in
            !key.hasPrefix("mapping.leds.color_message") && !set.contains(key) && !todo.contains { key == $0 || key.hasPrefix($0 + ".") }
                && !(general.contains { key.hasPrefix($0) } && (key.hasPrefix("mapping.leds.") || key.hasPrefix("mapping.notes.") ? todo.contains { key.hasPrefix($0) } : true))
        }.sorted()
        #expect(unexplained == [])
    }

    @Test("The LC6000's own facts: Play 1, pads 32-39, jog 17/49 with touch 40, pitch 8/40 up 0, needle 64/65/70, browse 6 two's complement, layer note 51, note 52 ignored")
    func facts() throws {
        let p = ProfileDraft.make(capture: try #require(Self.walked())).profile
        #expect(p.value(at: "mapping.notes.play") == .int(1))
        #expect(p.value(at: "mapping.notes.pads") == .array((32...39).map(DraftJSON.int)))
        #expect([p.value(at: "mapping.jog.msb_cc"), p.value(at: "mapping.jog.lsb_cc"), p.value(at: "mapping.notes.platter_touch")] == [.int(17), .int(49), .int(40)])
        #expect([p.value(at: "mapping.pitch.msb_cc"), p.value(at: "mapping.pitch.lsb_cc"), p.value(at: "mapping.pitch.invert")] == [.int(8), .int(40), .bool(false)])
        #expect([p.value(at: "mapping.needle.msb_cc"), p.value(at: "mapping.needle.lsb_cc"), p.value(at: "mapping.needle.touch_note")] == [.int(64), .int(65), .int(70)])
        #expect(p.value(at: "mapping.midi.encoder_format") == .string("twos_complement"))
        #expect(p.value(at: "mapping.midi.layer_note") == .int(51))
        #expect(p.value(at: "mapping.midi.ignore_notes") == .array([.int(52)]))
    }
}
