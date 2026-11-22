import Foundation
@testable import ControllerBridgeCore
import Testing

/// A 7-bit pitch fader on one CC (#195), beside the LC6000's 14-bit pair. Expected values worked by hand.
@Suite("7-bit fader mapping")
struct SevenBitFaderMappingTests {
    @Test("bits is 14 when left out; a 7-bit fader may leave out lsb_cc")
    func decoding() throws {
        let fourteen = #"{ "msb_cc": 8, "lsb_cc": 40, "invert": false, "dead_zone": 0.005 }"#
        let seven = #"{ "bits": 7, "msb_cc": 8, "invert": false, "dead_zone": 0.005 }"#
        #expect(try JSONDecoder().decode(Mapping.Pitch.self, from: Data(fourteen.utf8)).bits == 14)
        let pitch = try JSONDecoder().decode(Mapping.Pitch.self, from: Data(seven.utf8))
        #expect(pitch.bits == 7)
        #expect(pitch.lsbCC == nil)
    }

    @Test("The bundled LC6000 is 14-bit on CC 8 and 40, as before #195")
    func lc6000() throws {
        let pitch = try #require(try Mapping.bundledDefault().pitch)
        #expect([pitch.bits, pitch.msbCC, pitch.lsbCC] == [14, 8, 40])
    }
}

/// The 7-bit tempo mapping (#195): 64 is the exact center, so a centered fader reads 0. Below it each step is 1/64,
/// above it 1/63, so 0 and 127 reach -1 and +1.
@Suite("7-bit tempo")
struct SevenBitTempoTests {
    @Test("0, 32, 64, 96, 127 read -1, -0.5, 0, 0.507937, +1")
    func table() {
        let values = [0, 32, 64, 96, 127].map { tempoSlider(from7Bit: UInt8($0), invert: false, deadZone: 0) }
        #expect(values.map { ($0 * 1_000_000).rounded() / 1_000_000 } == [-1, -0.5, 0, 0.507937, 1])
    }

    @Test("invert flips it; within the dead zone it snaps to 0")
    func invertAndDeadZone() {
        #expect(tempoSlider(from7Bit: 0, invert: true, deadZone: 0) == 1)
        #expect(tempoSlider(from7Bit: 65, invert: false, deadZone: 0.02) == 0)   // 1/63 = 0.0159, inside 0.02
        #expect(tempoSlider(from7Bit: 66, invert: false, deadZone: 0.02) == 2.0 / 63)
    }
}

/// The Coordinator seam (#195): a test-only profile whose pitch fader is 7-bit on CC 8. Values rounded to 5 places as
/// the bridge sends them: 0x60 (96) is 32/63 = 0.50794, 0x70 (112) is 48/63 = 0.76190, 0x00 is -1, 0x40 is 0.
@Suite("7-bit fader at the Coordinator")
struct SevenBitFaderCoordinatorTests {
    static let sevenBit = #"{ "pitch": { "bits": 7 } }"#

    @Test("Each CC 8 value is a tempo on its own: 0x40 is 0, 0x60 is 0.50794, 0x00 is -1; CC 40 does nothing")
    func tempo() throws {
        let rig = try PickupTests.started(Self.sevenBit)
        PickupTests.fader(rig, 0x40)
        PickupTests.fader(rig, 0x60)
        rig.coordinator.midi(.controlChange(channel: 0, controller: 40, value: 0x7F), source: Rig.lc6000.id)
        PickupTests.fader(rig, 0x00)
        #expect(rig.osc.sent == [PickupTests.tempo(0), PickupTests.tempo(0.50794), PickupTests.tempo(-1)])
    }

    @Test("Pickup as on 14-bit: after a load at 0.5, nothing until the fader meets it, then it follows")
    func pickup() throws {
        let rig = try PickupTests.started(Self.sevenBit)
        PickupTests.report(rig, "Loaded", .int(1))
        PickupTests.report(rig, "TempoSlider", .float(0.5))
        PickupTests.fader(rig, 0x00)
        #expect(rig.osc.sent == [])
        PickupTests.fader(rig, 0x60)
        PickupTests.fader(rig, 0x70)
        #expect(rig.osc.sent == [PickupTests.tempo(0.50794), PickupTests.tempo(0.7619)])
    }

    @Test("The LC6000 is unchanged: 14-bit, 0x60 with LSB 0 is 0.50009")
    func lc6000() throws {
        let rig = try PickupTests.started()
        PickupTests.fader(rig, 0x60)
        #expect(rig.osc.sent == [PickupTests.tempo(0.50009)])
    }
}

/// The import check and decoder (#195), in plain words.
@Suite("7-bit fader in the import check")
struct SevenBitFaderImportTests {
    @Test("bits is 7 or 14")
    func bitsChoice() {
        #expect(throws: MappingError.invalid(["mapping.pitch.bits: 10 isn't one of 7, 14"])) {
            try ControllerProfile.importing(Data(#"{"mapping": {"pitch": {"bits": 10}}}"#.utf8),
                                            bundled: try ControllerProfile.bundled(), active: "denon-lc6000-prime")
        }
    }

    @Test("A 14-bit fader without lsb_cc says what's missing, for a whole profile body")
    func missingLSB() throws {
        var body = try #require(try JSONSerialization.jsonObject(with: Mapping.defaultMappingJSON()) as? [String: Any])
        var pitch = try #require(body["pitch"] as? [String: Any])
        pitch["lsb_cc"] = nil
        body["pitch"] = pitch
        #expect(throws: MappingError.invalid(["pitch: lsb_cc is missing (or set bits to 7)"])) {
            try Mapping.checked(try JSONSerialization.data(withJSONObject: body))
        }
    }
}
