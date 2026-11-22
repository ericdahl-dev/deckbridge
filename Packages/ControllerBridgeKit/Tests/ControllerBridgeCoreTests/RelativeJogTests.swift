import Foundation
@testable import ControllerBridgeCore
import Testing

/// A jog that sends relative ticks on one CC (#204), as most Pioneer DDJ platters do, beside the LC6000's absolute
/// 14-bit position. Expected values are worked by hand.
@Suite("Relative jog mapping")
struct RelativeJogMappingTests {
    static let relativeJog = #"""
    { "relative_cc": 33, "relative_edge_cc": 34, "counts_per_rev": 720, "bend_release_ms": 80,
      "seek_seconds_per_rev": 2.0, "beats_per_rev": 4, "require_touch": false }
    """#

    @Test("A jog with relative_cc is relative, and may leave out the 14-bit pair")
    func relative() throws {
        let jog = try JSONDecoder().decode(Mapping.Jog.self, from: Data(Self.relativeJog.utf8))
        #expect(jog.mode == .relative(cc: 33, edgeCC: 34))
    }

    @Test("The LC6000's jog is the absolute 14-bit pair on CC 17 and 49, as before #204")
    func lc6000Absolute() throws {
        #expect(try Mapping.bundledDefault().jog?.mode == .absolute(msbCC: 17, lsbCC: 49))
    }
}

/// The Coordinator seam (#204): a test-only profile whose platter sends offset-64 ticks on CC 33 (the top) and CC 34
/// (the edge), 720 ticks a turn. CC 33 and 34 are free in the LC6000 mapping.
@Suite("Relative jog at the Coordinator")
struct RelativeJogCoordinatorTests {
    static let profile = #"""
    { "midi": { "encoder_format": "offset_64" },
      "jog": { "relative_cc": 33, "relative_edge_cc": 34, "counts_per_rev": 720, "seek_seconds_per_rev": 4, "beats_per_rev": 4 } }
    """#

    static func started(_ override: String = profile) throws -> Rig {
        let rig = try Rig(override: override)
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        return rig
    }

    static func turn(_ rig: Rig, cc: UInt8 = 33, _ value: UInt8) {
        rig.coordinator.midi(.controlChange(channel: 0, controller: cc, value: value), source: Rig.lc6000.id)
    }

    static func playing(_ rig: Rig) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
    }

    @Test("Playing, a forward tick (0x41) nudges forward; a back tick (0x3F) turns the nudge around")
    func nudge() throws {
        let rig = try Self.started()
        Self.playing(rig)
        Self.turn(rig, 0x41)
        Self.turn(rig, 0x42)
        Self.turn(rig, 0x3F)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(-1)]),
        ])
    }

    @Test("Playing, PhaseBend 0 follows bend_release_ms (80) after the last tick")
    func release() throws {
        let rig = try Self.started()
        Self.playing(rig)
        Self.turn(rig, 0x41)
        rig.clock.now = 0.05
        rig.coordinator.tick()
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)])])
        rig.clock.now = 0.2
        rig.coordinator.tick()
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)]),
        ])
    }

    static func trackInfo(_ rig: Rig, seconds: Float) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/TrackInfo", [
            .string("t"), .string("a"), .string("8A"), .float(120), .float(seconds), .int(100), .int(400), .string("track"),
        ]))
    }

    @Test("Paused, 16 ticks (0x50) of 720 a turn seek 16/720 x 4 s of a 200 s track: from 0.5 to 0.5004444")
    func seekWhilePaused() throws {
        let rig = try Self.started()
        Self.trackInfo(rig, seconds: 200)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Progress", [.float(0.5)]))
        Self.turn(rig, 0x50)
        guard case .float(let position)? = rig.osc.sent.last?.arguments.first else {
            Issue.record("expected a float WaveformSeek, got \(rig.osc.sent)")
            return
        }
        #expect(rig.osc.sent.last?.address == "/Syndicate/Deck/1/WaveformSeek")
        #expect(abs(position - 0.500_444_4) < 0.000_000_5)
    }

    @Test("Paused with no track length, 180 ticks (720 a turn, 4 beats) skip a beat; 63 + 63 aren't one yet")
    func beatSkipWhilePaused() throws {
        let rig = try Self.started()
        Self.turn(rig, 0x7F)   // +63
        Self.turn(rig, 0x7F)   // +126
        #expect(rig.osc.sent == [])
        Self.turn(rig, 0x7F)   // +189: one beat, 9 left over
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/BeatSkip", [.int(1)])])
    }

    static let touchProfile = #"""
    { "midi": { "encoder_format": "offset_64" },
      "jog": { "relative_cc": 33, "relative_edge_cc": 34, "counts_per_rev": 720, "require_touch": true } }
    """#

    static func touch(_ rig: Rig, _ down: Bool) {
        // The platter's touch note, 40 in the LC6000 mapping.
        rig.coordinator.midi(down ? .noteOn(channel: 0, note: 40, velocity: 127) : .noteOff(channel: 0, note: 40, velocity: 0),
                             source: Rig.lc6000.id)
    }

    @Test("With require_touch, the top does nothing until touched, bends while touched, and letting go ends the bend")
    func touchTop() throws {
        let rig = try Self.started(Self.touchProfile)
        Self.playing(rig)
        Self.turn(rig, 0x41)
        #expect(rig.osc.sent == [])
        Self.touch(rig, true)
        Self.turn(rig, 0x41)
        Self.touch(rig, false)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)]),
        ])
    }

    @Test("The edge (CC 34) needs no touch: with require_touch it still nudges")
    func edgeWithoutTouch() throws {
        let rig = try Self.started(Self.touchProfile)
        Self.playing(rig)
        Self.turn(rig, cc: 34, 0x3F)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(-1)])])
    }

    @Test("Without require_touch, the top turns without a touch, as the LC6000's does")
    func noTouchNeeded() throws {
        let rig = try Self.started()
        Self.playing(rig)
        Self.turn(rig, 0x41)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)])])
    }

    @Test("The LC6000 is unchanged: CC 33 does nothing, and its 14-bit pair (17/49) still nudges by position")
    func lc6000Unchanged() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        Self.playing(rig)
        Self.turn(rig, 0x41)                                      // not a jog CC on the LC6000
        for (msb, lsb) in [(UInt8(7), UInt8(104)), (7, 112)] {   // position 1000, then 1008: 8 counts forward
            Self.turn(rig, cc: 17, msb)
            Self.turn(rig, cc: 49, lsb)
        }
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)])])
    }
}

/// The import check and the profile decoder (#204), in plain words.
@Suite("Relative jog in the import check")
struct RelativeJogImportTests {
    static func importing(_ json: String) throws -> ControllerProfile {
        try ControllerProfile.importing(Data(json.utf8), bundled: try ControllerProfile.bundled(), active: "denon-lc6000-prime")
    }

    @Test("relative_cc is a CC, 0-127")
    func range() {
        #expect(throws: MappingError.invalid(["mapping.jog.relative_cc: 200 is out of range, expected 0-127"])) {
            try Self.importing(#"{"mapping": {"jog": {"relative_cc": 200}}}"#)
        }
    }

    @Test("relative_cc can't be a CC another control already uses")
    func duplicate() {
        #expect(throws: MappingError.invalid(["mapping.jog.relative_cc: CC 6 is also browse.select_turn_cc"])) {
            try Self.importing(#"{"mapping": {"jog": {"relative_cc": 6}}}"#)
        }
    }

    @Test("A jog with neither a 14-bit pair nor relative_cc says what it needs; half a pair names the missing one")
    func needsAPairOrRelative() {
        let decode = { (json: String) in try JSONDecoder().decode(Mapping.Jog.self, from: Data(json.utf8)) }
        let rest = #""counts_per_rev": 720, "bend_release_ms": 80, "seek_seconds_per_rev": 2, "beats_per_rev": 4, "require_touch": false"#
        #expect(throws: Mapping.JogError.needsPairOrRelative) { try decode("{ \(rest) }") }
        #expect(throws: Mapping.JogError.missing("lsb_cc")) { try decode(#"{ "msb_cc": 17, "# + rest + "}") }
        #expect(Mapping.JogError.needsPairOrRelative.description == "jog: needs msb_cc and lsb_cc, or relative_cc")
        #expect(Mapping.JogError.missing("lsb_cc").description == "jog: lsb_cc is missing (or set relative_cc for a relative jog)")
    }

    @Test("A whole profile body whose jog has half a pair fails the check with those words, not a decoding dump")
    func wholeBodyHalfPair() throws {
        var body = try #require(try JSONSerialization.jsonObject(with: Mapping.defaultMappingJSON()) as? [String: Any])
        var jog = try #require(body["jog"] as? [String: Any])
        jog["msb_cc"] = nil
        body["jog"] = jog
        let json = try JSONSerialization.data(withJSONObject: body)
        #expect(throws: MappingError.invalid(["jog: msb_cc is missing (or set relative_cc for a relative jog)"])) {
            try Mapping.checked(json)
        }
    }
}

/// The demo on a relative-jog profile (#204): App Review sees the same nudge on any controller.
@Suite("Relative jog in the demo")
struct RelativeJogDemoTests {
    @Test("On an offset-64 relative profile, the demo's jog still nudges: PhaseBend 1, then 0, by 3.5 s")
    func demoNudges() throws {
        var profile = try ControllerProfile.bundled()[0]
        profile.mapping.midi.encoderFormat = .offset64
        profile.mapping.jog?.relativeCC = 33
        let clock = Rig.FakeClock()
        let session = DemoSession(profile: profile, clock: clock, log: Rig.FakeLog(), ledOutput: Rig.FakeOutput())
        session.start()
        while clock.now + 0.01 <= 3.5 + 1e-9 {
            clock.now += 0.01
            session.tick()
        }
        let bends = session.sentToSyndicate.filter { $0.address == "/Syndicate/Deck/1/PhaseBend" }
        #expect(bends == [
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)]),
        ])
    }

    @Test("A tick count encodes back to each format's value: +8 is 0x08, 0x48, 0x08; -1 is 0x7F, 0x3F, 0x41")
    func encode() {
        #expect([EncoderFormat.twosComplement, .offset64, .signMagnitude].map { $0.value(forTicks: 8) } == [0x08, 0x48, 0x08])
        #expect([EncoderFormat.twosComplement, .offset64, .signMagnitude].map { $0.value(forTicks: -1) } == [0x7F, 0x3F, 0x41])
    }
}
