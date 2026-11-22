import Foundation
@testable import ControllerBridgeCore
import Testing

/// A controller that lacks a control leaves its section out (#341): the DDJ-400 has no needle strip. The profile
/// loads, and nothing is listened for or sent for the missing control.
@Suite("Optional sections")
struct OptionalSectionsTests {
    /// The bundled LC6000 as a whole profile file, without `sections`.
    static func profile(without sections: [String]) throws -> ControllerProfile {
        var mapping = try JSONSerialization.jsonObject(with: Mapping.defaultMappingJSON()) as! [String: Any]
        for section in sections { mapping[section] = nil }
        let file: [String: Any] = ["id": "test-lc6000-lite", "name": "Test lite", "device_hints": ["LC6000"], "mapping": mapping]
        return try ControllerProfile(decoding: JSONSerialization.data(withJSONObject: file, options: .sortedKeys))
    }

    static func rig(_ profile: ControllerProfile) -> Rig {
        let rig = Rig(mapping: profile.mapping)
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        return rig
    }

    @Test("No needle: the profile loads, and the LC6000's needle CCs and touch note send nothing")
    func noNeedle() throws {
        let profile = try Self.profile(without: ["needle"])
        #expect(profile.mapping.needle == nil)
        let rig = Self.rig(profile)
        rig.coordinator.midi(.noteOn(channel: 0, note: 70, velocity: 127), source: Rig.lc6000.id)
        rig.coordinator.midi(.controlChange(channel: 0, controller: 64, value: 40), source: Rig.lc6000.id)
        rig.coordinator.midi(.controlChange(channel: 0, controller: 65, value: 0), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [])
    }

    @Test("The LC6000 still has its needle: CCs 64 and 65, touch note 70")
    func lc6000Needle() throws {
        let needle = try #require(try Mapping.bundledDefault().needle)
        #expect(needle.msbCC == 64 && needle.lsbCC == 65 && needle.touchNote == 70)
    }
}

/// No browse knob (#341): the section left out, its CCs do nothing.
@Suite("Optional browse")
struct OptionalBrowseTests {
    @Test("No browse: the profile loads, and the LC6000's browse CCs (6 and 3) send nothing")
    func noBrowse() throws {
        let profile = try OptionalSectionsTests.profile(without: ["browse"])
        #expect(profile.mapping.browse == nil)
        let rig = OptionalSectionsTests.rig(profile)
        rig.coordinator.midi(.controlChange(channel: 0, controller: 6, value: 1), source: Rig.lc6000.id)
        rig.coordinator.midi(.controlChange(channel: 0, controller: 3, value: 1), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [])
    }

    @Test("The LC6000 still has its browse knob: select CC 6, auto loop size CC 3")
    func lc6000Browse() throws {
        let browse = try #require(try Mapping.bundledDefault().browse)
        #expect(browse.selectTurnCC == 6 && browse.autoLoopSizeCC == 3)
    }
}

/// No pitch fader (#341): the section left out, its CCs do nothing, and the demo skips its fader move.
@Suite("Optional pitch")
struct OptionalPitchTests {
    @Test("No pitch: the profile loads, and the LC6000's pitch CCs (8 and 40) send nothing")
    func noPitch() throws {
        let profile = try OptionalSectionsTests.profile(without: ["pitch"])
        #expect(profile.mapping.pitch == nil)
        let rig = OptionalSectionsTests.rig(profile)
        rig.coordinator.midi(.controlChange(channel: 0, controller: 8, value: 70), source: Rig.lc6000.id)
        rig.coordinator.midi(.controlChange(channel: 0, controller: 40, value: 0), source: Rig.lc6000.id)
        #expect(rig.osc.sent == [])
    }

    @Test("The demo runs a profile with no pitch fader: no tempo is ever sent")
    func demo() throws {
        let clock = Rig.FakeClock()
        let session = DemoSession(profile: try OptionalSectionsTests.profile(without: ["pitch"]), clock: clock,
                                  log: Rig.FakeLog(), ledOutput: Rig.FakeOutput())
        session.start()
        for _ in 0..<900 { clock.now += 0.01; session.tick() }
        #expect(session.sentToSyndicate.contains { $0.address.hasSuffix("/PlayPause") }, "the demo still ran")
        #expect(!session.sentToSyndicate.contains { $0.address.hasSuffix("/TempoSlider") })
    }

    @Test("The LC6000 still has its pitch fader: 14 bits on CCs 8 and 40")
    func lc6000Pitch() throws {
        let pitch = try #require(try Mapping.bundledDefault().pitch)
        #expect(pitch.bits == 14 && pitch.msbCC == 8 && pitch.lsbCC == 40)
    }
}

/// No jog wheel (#341): the section left out, its CCs and touch do nothing, and the demo skips its nudge.
@Suite("Optional jog")
struct OptionalJogTests {
    @Test("No jog: the profile loads, and the LC6000's jog CCs (17 and 49) send nothing while playing")
    func noJog() throws {
        let profile = try OptionalSectionsTests.profile(without: ["jog"])
        #expect(profile.mapping.jog == nil)
        let rig = OptionalSectionsTests.rig(profile)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        rig.osc.sent.removeAll()
        for (msb, lsb) in [(UInt8(7), UInt8(100)), (7, 120)] {
            rig.coordinator.midi(.controlChange(channel: 0, controller: 17, value: msb), source: Rig.lc6000.id)
            rig.coordinator.midi(.controlChange(channel: 0, controller: 49, value: lsb), source: Rig.lc6000.id)
        }
        rig.clock.now = 1
        rig.coordinator.tick()
        #expect(rig.osc.sent == [])
    }

    @Test("The demo runs a profile with no jog: no nudge is ever sent")
    func demo() throws {
        let clock = Rig.FakeClock()
        let session = DemoSession(profile: try OptionalSectionsTests.profile(without: ["jog"]), clock: clock,
                                  log: Rig.FakeLog(), ledOutput: Rig.FakeOutput())
        session.start()
        for _ in 0..<900 { clock.now += 0.01; session.tick() }
        #expect(session.sentToSyndicate.contains { $0.address.hasSuffix("/PlayPause") }, "the demo still ran")
        #expect(!session.sentToSyndicate.contains { $0.address.hasSuffix("/PhaseBend") })
    }

    @Test("The LC6000 still has its jog: the 17/49 pair, 3600 counts a turn")
    func lc6000Jog() throws {
        let jog = try #require(try Mapping.bundledDefault().jog)
        #expect(jog.mode == .absolute(msbCC: 17, lsbCC: 49) && jog.countsPerRev == 3600)
    }
}
