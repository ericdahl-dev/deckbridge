import ControllerBridgeCore
import Foundation
import Testing

/// Picking a controller profile by device name (#43), at the Coordinator seam. Which device a controller then binds
/// to (saved unique id first, then name) is #20's.
@Suite("Profile matching")
struct ProfileMatchingTests {
    /// A Coordinator over the given profiles and MIDI sources, with a destination named like each source.
    final class ProfileRig {
        let midi: Rig.FakeMIDISystem
        let osc = Rig.FakeOSC()
        let log = Rig.FakeLog()
        let clock = Rig.FakeClock()
        let coordinator: Coordinator

        init(profiles: [ControllerProfile], sources: [MIDIEndpoint]) {
            midi = Rig.FakeMIDISystem(
                sources: sources,
                destinations: sources.map { MIDIEndpoint(id: $0.id + 1000, name: $0.name) }
            )
            coordinator = Coordinator(profiles: profiles, midi: midi, osc: osc, clock: clock, log: log)
        }
    }

    static let iac = MIDIEndpoint(id: 1000, name: "IAC Bus 1")
    static let lc6000 = MIDIEndpoint(id: 1001, name: "DENON LC6000 PRIME")

    @Test("A device whose name matches a profile's hint gets that profile; a device with none is listed but not bridged")
    func matchesByDeviceName() throws {
        let rig = ProfileRig(profiles: try ControllerProfile.bundled(), sources: [Self.iac, Self.lc6000])
        rig.coordinator.start()

        #expect(rig.midi.connected == [Self.lc6000.id])
        #expect(rig.coordinator.status.devices == [
            DeviceStatus(name: "IAC Bus 1", profile: nil, note: "No controller profile matches IAC Bus 1, so it isn't bridged."),
            DeviceStatus(name: "DENON LC6000 PRIME", profile: "Denon LC6000 PRIME", note: nil),
        ])
        #expect(rig.coordinator.status.controllers.map(\.profile) == ["Denon LC6000 PRIME"])
    }

    @Test("A profile's own other port, like the LC6000's WD port, is listed as part of that controller, not as unsupported (#200)")
    func ownOtherPort() throws {
        let wd = MIDIEndpoint(id: 1005, name: "DENON LC6000 PRIME WD")
        let rig = ProfileRig(profiles: try ControllerProfile.bundled(), sources: [Self.lc6000, wd])
        rig.coordinator.start()

        #expect(rig.midi.connected == [Self.lc6000.id])
        #expect(rig.coordinator.status.devices == [
            DeviceStatus(name: "DENON LC6000 PRIME", profile: "Denon LC6000 PRIME", note: nil),
            DeviceStatus(
                name: "DENON LC6000 PRIME WD", profile: nil, note: "DENON LC6000 PRIME WD is another port of the Denon LC6000 PRIME.",
                partOf: "Denon LC6000 PRIME"
            ),
        ])
        #expect(!rig.log.lines.contains { $0.hasPrefix("No controller profile matches") })
    }

    static let other = MIDIEndpoint(id: 1002, name: "Some Other Controller")

    @Test("With no matching device nothing is bridged: the device is listed with a plain message, and logged")
    func noMatch() throws {
        let rig = ProfileRig(profiles: try ControllerProfile.bundled(), sources: [Self.other])
        rig.coordinator.start()
        rig.osc.sent.removeAll()

        #expect(rig.midi.connected == [])
        #expect(rig.coordinator.status.devices == [
            DeviceStatus(name: "Some Other Controller", profile: nil, note: "No controller profile matches Some Other Controller, so it isn't bridged."),
        ])
        #expect(rig.coordinator.status.controllers.map(\.profile) == [nil])
        #expect(rig.log.lines.contains("No controller profile matches Some Other Controller, so it isn't bridged."))

        rig.coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Self.other.id)
        #expect(rig.osc.sent == [])
        // A later device-list change lists it again but doesn't log it twice.
        rig.coordinator.devicesChanged()
        #expect(rig.log.lines.filter { $0.hasPrefix("No controller profile matches") }.count == 1)
    }

    @Test("Hints match without regard to case")
    func hintIgnoresCase() throws {
        let lower = MIDIEndpoint(id: 1003, name: "denon lc6000 prime")
        let rig = ProfileRig(profiles: try ControllerProfile.bundled(), sources: [lower])
        rig.coordinator.start()
        #expect(rig.midi.connected == [lower.id])
        #expect(rig.coordinator.status.controllers.map(\.profile) == ["Denon LC6000 PRIME"])
    }

    @Test("A second controller is just a profile file: a TP-1 device gets Test Pad, and its own Play note sends PlayPause")
    func secondProfileBridges() throws {
        let testPad = try ControllerProfile(decoding: ProfileTests.testPadFile())
        let pad = MIDIEndpoint(id: 1004, name: "TP-1 Pad")
        let rig = ProfileRig(profiles: try ControllerProfile.bundled() + [testPad], sources: [Self.iac, pad])
        rig.coordinator.start()
        rig.osc.sent.removeAll()

        #expect(rig.midi.connected == [pad.id])
        #expect(rig.coordinator.status.controllers.map(\.profile) == ["Test Pad"])
        // Test Pad's Play is note 60 on MIDI channel 2 (1 when 0-based); the LC6000's note 1 does nothing here.
        rig.coordinator.midi(.noteOn(channel: 1, note: 1, velocity: 127), source: pad.id)
        rig.coordinator.midi(.noteOn(channel: 1, note: 60, velocity: 127), source: pad.id)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])])
    }

    @Test("If two profiles match one device, the one with the longest matching hint wins, and that is logged")
    func longestHintWins() throws {
        var mk2 = try ControllerProfile(decoding: ProfileTests.testPadFile())
        mk2.name = "LC6000 MK2 (test)"
        mk2.deviceHints = ["LC6000 PRIME MK2"]
        let device = MIDIEndpoint(id: 1005, name: "DENON LC6000 PRIME MK2")
        // The shorter, bundled "LC6000" hint is listed first, so order alone wouldn't pick MK2.
        let rig = ProfileRig(profiles: try ControllerProfile.bundled() + [mk2], sources: [device])
        rig.coordinator.start()

        #expect(rig.coordinator.status.controllers.map(\.profile) == ["LC6000 MK2 (test)"])
        #expect(rig.log.lines.contains(
            "DENON LC6000 PRIME MK2 matches Denon LC6000 PRIME and LC6000 MK2 (test); using LC6000 MK2 (test), whose hint is longest."
        ))
    }

    @Test("If two profiles' matching hints are equally long, the first listed profile wins")
    func tieGoesToFirst() throws {
        var a = try ControllerProfile(decoding: ProfileTests.testPadFile())
        a.name = "Pad A"
        a.deviceHints = ["PAD-X"]
        var b = a
        b.name = "Pad B"
        let device = MIDIEndpoint(id: 1006, name: "PAD-X USB")
        for (profiles, expected) in [([a, b], "Pad A"), ([b, a], "Pad B")] {
            let rig = ProfileRig(profiles: profiles, sources: [device])
            rig.coordinator.start()
            #expect(rig.coordinator.status.controllers.map(\.profile) == [expected])
        }
    }

    // A real LC6000 PRIME is two MIDI ports (#99). In lc6000-cos's capture, every message came from "…Controller";
    // "…WD" sent nothing.
    static let wd = MIDIEndpoint(id: 1010, name: "Denon DJ LC6000 PRIME WD")
    static let controls = MIDIEndpoint(id: 1011, name: "Denon DJ LC6000 PRIME LC6000 PRIME Controller")

    final class TwoPortRig {
        let midi: Rig.FakeMIDISystem
        let log = Rig.FakeLog()
        let coordinator: Coordinator

        init(sources: [MIDIEndpoint]) throws {
            midi = Rig.FakeMIDISystem(
                sources: sources,
                destinations: sources.map { MIDIEndpoint(id: $0.id + 1000, name: $0.name) }
            )
            coordinator = Coordinator(profiles: try ControllerProfile.bundled(), midi: midi, osc: Rig.FakeOSC(), clock: Rig.FakeClock(), log: log)
            coordinator.start()
        }
    }

    @Test("A real LC6000's two ports: the bridge connects the Controller port, not the silent WD port, in either order", arguments: [
        [wd, controls], [controls, wd],
    ])
    func connectsControlsPort(sources: [MIDIEndpoint]) throws {
        let rig = try TwoPortRig(sources: sources)
        #expect(rig.midi.connected == [Self.controls.id])
        // The LEDs go to the destination with the connected source's name, not the WD destination.
        #expect(rig.midi.outputs[Self.controls.id + 1000] != nil)
        #expect(rig.midi.outputs[Self.wd.id + 1000] == nil)
    }

    @Test("The WD port is listed as a device no profile matches, and isn't bridged")
    func wdNotBridged() throws {
        let rig = try TwoPortRig(sources: [Self.wd, Self.controls])
        #expect(rig.coordinator.status.devices.first { $0.name == Self.wd.name }?.profile == nil)
        #expect(rig.coordinator.status.devices.first { $0.name == Self.controls.name }?.profile == "Denon LC6000 PRIME")
    }

    @Test("Two automatic controllers with one LC6000: the second waits for another unit and doesn't take WD")
    func secondControllerSkipsWD() throws {
        let rig = try TwoPortRig(sources: [Self.wd, Self.controls])
        rig.coordinator.setControllers([
            ControllerSettings(deck: 1, input: nil, output: nil),
            ControllerSettings(deck: 2, input: nil, output: nil),
        ])
        #expect(rig.midi.connected == [Self.controls.id])
    }

    // MARK: A profile chosen by hand (#200)

    static let mystery = MIDIEndpoint(id: 1006, name: "Mystery DJ 2")

    @Test("A device no profile names runs once the DJ chooses a profile for it, and stops when they go back to Automatic")
    func chosenByHand() throws {
        let rig = ProfileRig(profiles: try ControllerProfile.bundled(), sources: [Self.mystery])
        rig.coordinator.start()
        #expect(rig.midi.connected == [])

        rig.coordinator.setProfileChoices(["Mystery DJ 2": "denon-lc6000-prime"])
        #expect(rig.midi.connected == [Self.mystery.id])
        #expect(rig.coordinator.status.controllers.map(\.profile) == ["Denon LC6000 PRIME"])
        #expect(rig.coordinator.status.devices == [DeviceStatus(name: "Mystery DJ 2", profile: "Denon LC6000 PRIME", note: nil)])
        rig.osc.sent.removeAll()
        rig.coordinator.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Self.mystery.id)
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)]))

        rig.coordinator.setProfileChoices([:])
        #expect(rig.midi.connected == [])
        #expect(rig.coordinator.status.devices.map(\.profile) == [nil])
    }

    @Test("A choice beats the name: a TP-1 Pad set to the LC6000 profile runs as an LC6000")
    func choiceBeatsHints() throws {
        let testPad = try ControllerProfile(decoding: ProfileTests.testPadFile())
        let pad = MIDIEndpoint(id: 1004, name: "TP-1 Pad")
        let rig = ProfileRig(profiles: try ControllerProfile.bundled() + [testPad], sources: [pad])
        rig.coordinator.start()
        #expect(rig.coordinator.status.controllers.map(\.profile) == ["Test Pad"])

        rig.coordinator.setProfileChoices(["TP-1 Pad": "denon-lc6000-prime"])
        #expect(rig.midi.connected == [pad.id])
        #expect(rig.coordinator.status.controllers.map(\.profile) == ["Denon LC6000 PRIME"])
    }

    @Test("A choice naming a profile that no longer exists is Automatic")
    func unknownChoiceIsAutomatic() throws {
        let rig = ProfileRig(profiles: try ControllerProfile.bundled(), sources: [Self.lc6000])
        rig.coordinator.start()
        rig.coordinator.setProfileChoices(["DENON LC6000 PRIME": "gone-controller"])
        #expect(rig.midi.connected == [Self.lc6000.id])
        #expect(rig.coordinator.status.controllers.map(\.profile) == ["Denon LC6000 PRIME"])
    }

    @Test("Each controller's status names the device it runs on, so Settings can offer a profile for it; none while unplugged")
    func controllerNamesItsDevice() throws {
        let rig = ProfileRig(profiles: try ControllerProfile.bundled(), sources: [Self.iac, Self.lc6000])
        rig.coordinator.start()
        #expect(rig.coordinator.status.controllers.map(\.device) == ["DENON LC6000 PRIME"])
        rig.midi.sources = [Self.iac]
        rig.coordinator.devicesChanged()
        #expect(rig.coordinator.status.controllers.map(\.device) == [nil])
    }

    @Test("Back to Automatic with an LC6000 plugged in meanwhile: the controller moves to the LC6000, not left on the unknown device")
    func automaticMovesToTheMatch() throws {
        let rig = ProfileRig(profiles: try ControllerProfile.bundled(), sources: [Self.mystery])
        rig.coordinator.start()
        rig.coordinator.setProfileChoices(["Mystery DJ 2": "denon-lc6000-prime"])
        rig.midi.sources = [Self.mystery, Self.lc6000]
        rig.midi.destinations = [Self.mystery, Self.lc6000].map { MIDIEndpoint(id: $0.id + 1000, name: $0.name) }
        rig.coordinator.devicesChanged()
        #expect(rig.midi.connected == [Self.mystery.id])

        rig.coordinator.setProfileChoices([:])
        #expect(rig.midi.connected == [Self.lc6000.id])
        #expect(rig.coordinator.status.controllers.map(\.device) == ["DENON LC6000 PRIME"])
    }
}
