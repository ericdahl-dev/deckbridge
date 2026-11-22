import ControllerBridgeCore
import Testing

/// The Engine is the one consumer loop: events go in through an EventPipe, and the Rig's fakes show what came out.
@Suite("Engine")
struct EngineTests {
    @Test("A Play press from the pipe reaches Syndicate as PlayPause 1")
    func midiFromThePipeReachesTheCoordinator() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        let pipe = EventPipe()

        pipe.producer.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])])
    }

    @Test("Profile choices from the pipe reach the Coordinator: a device no profile names runs as the LC6000 (#200)")
    func profileChoicesFromThePipe() async throws {
        let mystery = MIDIEndpoint(id: 1006, name: "Mystery DJ 2")
        let midi = Rig.FakeMIDISystem(sources: [mystery], destinations: [MIDIEndpoint(id: 2006, name: "Mystery DJ 2")])
        let osc = Rig.FakeOSC(), log = Rig.FakeLog()
        let coordinator = Coordinator(profiles: try ControllerProfile.bundled(), midi: midi, osc: osc, clock: Rig.FakeClock(), log: log)
        coordinator.start()
        let pipe = EventPipe()

        pipe.producer.send(.setProfileChoices(["Mystery DJ 2": "denon-lc6000-prime"]))
        pipe.producer.finish()
        await Engine(coordinator: coordinator, log: log).run(pipe.events)

        #expect(midi.connected == [mystery.id])
    }

    @Test("A capture from the pipe pauses the controller, and nil gives it back (#186)")
    func captureFromThePipe() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        let pipe = EventPipe()

        pipe.producer.send(.setCapture(source: Rig.lc6000.id))
        pipe.producer.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.midi(.noteOff(channel: 0, note: 1, velocity: 0), source: Rig.lc6000.id)
        pipe.producer.send(.setCapture(source: nil))
        pipe.producer.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/Cue", [.int(1)])])
    }

    @Test("A Playing 1 datagram from the pipe is decoded and lights the Play LED full")
    func udpFromThePipeIsDecodedAsFeedback() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        let pipe = EventPipe()

        // "/Syndicate/Deck/1/Playing" is 25 bytes, + NUL = 26, padded to 28. Then ",i" + 2 NULs, then int32 1.
        pipe.producer.udp(OSCCodecTests.bytes("""
            2f53796e 64696361 74652f44 65636b2f 312f506c 6179696e 67000000
            2c690000
            00000001
            """))
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.leds[1] == 127)
    }

    @Test("A datagram that isn't OSC is logged and dropped, and the events after it still arrive")
    func badDatagramIsLoggedAndTheLoopGoesOn() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        let pipe = EventPipe()

        pipe.producer.udp([0x00, 0x01, 0x02]) // 3 bytes: not a whole OSC message
        pipe.producer.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.log.lines.filter { $0.hasPrefix("Dropped a feedback datagram") }.count == 1)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])])
    }

    @Test("A tick from the pipe reaches the Coordinator: the jog nudge is released after the wheel stops")
    func tickFromThePipeReachesTheCoordinator() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        for (msb, lsb) in [(UInt8(7), UInt8(100)), (7, 90)] {   // the platter turning back (#103)
            rig.coordinator.midi(.controlChange(channel: 0, controller: 17, value: msb), source: Rig.lc6000.id)
            rig.coordinator.midi(.controlChange(channel: 0, controller: 49, value: lsb), source: Rig.lc6000.id)
        }
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(-1)]))
        rig.clock.now = 0.2
        let pipe = EventPipe()

        pipe.producer.tick()
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/PhaseBend", [.int(0)]))
    }

    @Test("A devices-changed event from the pipe connects a controller that appeared")
    func devicesChangedFromThePipe() async throws {
        let rig = try Rig()
        rig.midi.sources = []
        rig.midi.destinations = []
        rig.coordinator.start()
        rig.midi.sources = [Rig.lc6000]
        rig.midi.destinations = [Rig.lc6000Out]
        let pipe = EventPipe()

        pipe.producer.devicesChanged()
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.midi.connected == [Rig.lc6000.id])
    }

    @Test("A devices-changed event from the pipe carries what was removed (#429): the unit removed and back reconnects, releasing a held Cue")
    func removedFromThePipe() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)
        rig.osc.sent.removeAll()
        let pipe = EventPipe()

        pipe.producer.devicesChanged(removed: [Rig.lc6000.id])
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.osc.sent.contains(OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)])))
    }

    @Test("Sleep from the pipe releases a held Cue; wake re-checks the devices")
    func sleepAndWakeFromThePipe() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)
        rig.osc.sent.removeAll()
        let pipe = EventPipe()

        pipe.producer.sleep()
        pipe.producer.wake()
        pipe.producer.finish()
        rig.midi.sources = []
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)])])
        #expect(rig.midi.connected == [])
    }

    @Test("Stop from the pipe releases held controls before run() returns, and events after it are not handled")
    func stopFromThePipe() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)   // Cue held
        rig.osc.sent.removeAll()
        let pipe = EventPipe()

        pipe.producer.stop()
        pipe.producer.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)    // after quit: dropped
        // No finish(): stop alone ends the loop.
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)])])
        #expect(rig.midi.connected == [])
    }

    @Test("The status sink gets the Coordinator status once per change, not once per event")
    func statusSinkOnChange() async throws {
        let rig = try Rig()
        rig.midi.sources = []
        rig.midi.destinations = []
        rig.coordinator.start()
        rig.midi.sources = [Rig.lc6000]
        rig.midi.destinations = [Rig.lc6000Out]
        let pipe = EventPipe()
        let seen = Seen()

        pipe.producer.tick()
        pipe.producer.devicesChanged()
        pipe.producer.tick()
        pipe.producer.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, onStatus: { seen.append($0) }).run(pipe.events)

        var expected = [
            CoordinatorStatus(controllers: [ControllerStatus(deck: 1, connected: false, lastEvent: nil)]),
            CoordinatorStatus(
                controllers: [ControllerStatus(
                    deck: 1, connected: true, lastEvent: "Connected DENON LC6000 PRIME", profile: "Custom mapping", outputOpen: true,
                    lastProfile: "Custom mapping", device: "DENON LC6000 PRIME"
                )],
                devices: [DeviceStatus(name: "DENON LC6000 PRIME", profile: "Custom mapping", note: nil)]
            ),
        ]
        // The LC6000 asks for Volume too, for Shift + Needle Drop (#609).
        for index in expected.indices { expected[index].requiredSubscriptions = Subscription.always + [.mixerVolume] }
        #expect(seen.values == expected)
    }

    /// Collects what a Sendable callback is given.
    final class SeenDiagnostics: @unchecked Sendable {
        var values: [DiagnosticEvent] = []
        func append(_ event: DiagnosticEvent) { values.append(event) }
    }

    @Test("Diagnostics open and close through the pipe: events reach the window's sink only while it is open")
    func diagnosticsThroughThePipe() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        let pipe = EventPipe()
        let seen = SeenDiagnostics()

        pipe.producer.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)   // closed: not shown
        pipe.producer.diagnostics(open: true)
        pipe.producer.midi(.noteOn(channel: 0, note: 99, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.diagnostics(open: false)
        pipe.producer.midi(.noteOn(channel: 0, note: 98, velocity: 127), source: Rig.lc6000.id)   // closed again
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, onDiagnostic: { seen.append($0) }).run(pipe.events)

        #expect(seen.values.map(\.text).map { $0.hasSuffix(" UNMAPPED") } == [true])
    }

    @Test("The LED sweep starts and stops through the pipe")
    func sweepThroughThePipe() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        let pipe = EventPipe()
        let seen = SeenDiagnostics()

        pipe.producer.diagnostics(open: true)
        pipe.producer.send(.ledSweep(delay: 0.6))
        pipe.producer.send(.stopLEDSweep)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, onDiagnostic: { seen.append($0) }).run(pipe.events)

        #expect(seen.values.map(\.text) == [
            "Color sweep: velocity shown on every pad and the ring. Note what each looks like.",
            "  velocity  0 (0x00) = rgb222 r0 g0 b0",
            "LED sweep stopped.",
        ])
    }

    @Test("Quit from the pipe leaves our logo on a drawing jog display (#600): no end; the demo turning on still ends it")
    func quitLeavesTheLogo() async throws {
        let end = DrawnDisplay.Message.end(version: 1).bytes
        let (rig, port, _) = try DrawnDisplayHandshakeTests.rig(.custom)
        rig.coordinator.jogDisplayReply(DrawnDisplayHandshakeTests.answer)
        let pipe = EventPipe()
        pipe.producer.stop()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)
        #expect(!port.wd.contains(end))
        #expect(port.controller.last == JogDisplay.goodbye)

        let (demoRig, demoPort, _) = try DrawnDisplayHandshakeTests.rig(.custom)
        demoRig.coordinator.jogDisplayReply(DrawnDisplayHandshakeTests.answer)
        let demo = EventPipe()
        demo.producer.demo(on: true)
        demo.producer.finish()
        let clock = demoRig.clock, log = demoRig.log
        await Engine(coordinator: demoRig.coordinator, log: demoRig.log, makeDemo: { profile in
            DemoSession(profile: profile, clock: clock, log: log, ledOutput: Rig.FakeOutput())
        }).run(demo.events)
        #expect(demoPort.wd.contains(end))
    }

    /// A demo maker for the Engine, on the rig's clock, with its LED writes dropped.
    /// The demo runs the profile the Engine hands it: the one running now (#98).
    static func demoMaker(_ rig: Rig) -> @Sendable (ControllerProfile) -> DemoSession {
        let clock = rig.clock, log = rig.log
        return { profile in DemoSession(profile: profile, clock: clock, log: log, ledOutput: Rig.FakeOutput()) }
    }

    @Test("Demo on stops the real controller (one release, ports closed); its MIDI is ignored; demo off brings it back with one Resend")
    func demoSwapsCoordinators() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))   // a live Syndicate answered
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)   // Cue held
        rig.osc.sent.removeAll()
        let pipe = EventPipe()
        let seen = Seen()

        pipe.producer.demo(on: true)
        pipe.producer.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)    // real Play: ignored
        pipe.producer.tick()
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, onStatus: { seen.append($0) }, makeDemo: Self.demoMaker(rig))
            .run(pipe.events)

        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)])])   // nothing else reaches the network
        #expect(rig.midi.connected == [])
        #expect(seen.values.last?.demo == true)
        #expect(seen.values.last?.controllers.map(\.connected) == [true])
        #expect(seen.values.last?.feedback == .live)

        let back = EventPipe()
        rig.osc.sent.removeAll()
        back.producer.demo(on: true)
        back.producer.demo(on: false)
        back.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, onStatus: { seen.append($0) }, makeDemo: Self.demoMaker(rig))
            .run(back.events)
        #expect(rig.midi.connected == [Rig.lc6000.id])
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Feedback/Resend", [.int(1)])])
        #expect(seen.values.last?.demo == false)
    }

    @Test("Quitting during the demo stops it and ends the loop, with nothing sent to the network")
    func quitDuringDemo() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        let pipe = EventPipe()
        pipe.producer.demo(on: true)
        pipe.producer.tick()
        pipe.producer.stop()
        await Engine(coordinator: rig.coordinator, log: rig.log, makeDemo: Self.demoMaker(rig)).run(pipe.events)
        #expect(rig.osc.sent == [])
    }

    @Test("Settings changed during the demo wait, then apply to the real controller when the demo ends")
    func settingsWaitForDemoEnd() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        let pipe = EventPipe()
        pipe.producer.demo(on: true)
        pipe.producer.send(.setDeck(2, controller: 0))
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, makeDemo: Self.demoMaker(rig)).run(pipe.events)
        #expect(rig.osc.sent == [])
        #expect(rig.coordinator.status.controllers.map(\.deck) == [1])

        let back = EventPipe()
        back.producer.demo(on: true)
        back.producer.send(.setDeck(2, controller: 0))
        back.producer.demo(on: false)
        back.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, makeDemo: Self.demoMaker(rig)).run(back.events)
        #expect(rig.coordinator.status.controllers.map(\.deck) == [2])
    }

    @Test("Diagnostics follow the demo: its traffic shows in the OSC log")
    func diagnosticsFollowDemo() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        let pipe = EventPipe()
        let seen = SeenDiagnostics()
        pipe.producer.diagnostics(open: true)
        pipe.producer.demo(on: true)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, onDiagnostic: { seen.append($0) }, makeDemo: Self.demoMaker(rig))
            .run(pipe.events)
        #expect(seen.values.map(\.text).contains("OSC -> /Syndicate/Feedback/Resend 1"))
    }

    final class Seen: @unchecked Sendable {
        var values: [CoordinatorStatus] = []
        func append(_ status: CoordinatorStatus) { values.append(status) }
    }

    @Test("Settings changes from the pipe reach the Coordinator in order: deck, devices, LEDs")
    func settingsFromThePipe() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)   // Cue held
        rig.osc.sent.removeAll()
        let pipe = EventPipe()

        pipe.producer.send(.setDeck(2, controller: 0))
        pipe.producer.send(.setDevices(input: Rig.lc6000, output: Rig.lc6000Out, controller: 0))
        pipe.producer.send(.setLEDs(enabled: false))
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.osc.sent.first == OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)]))
        #expect(rig.coordinator.status.controllers.map(\.deck) == [2])
        #expect(rig.midi.connected == [Rig.lc6000.id])
        #expect(rig.leds.values.allSatisfy { $0 == 0 })
    }

    @Test("A controller list from the pipe reaches the Coordinator")
    func controllersFromThePipe() async throws {
        let rig = try Rig()
        let unitB = MIDIEndpoint(id: 1005, name: "DENON LC6000 PRIME")
        rig.midi.sources.append(unitB)
        rig.coordinator.start()
        let pipe = EventPipe()

        pipe.producer.send(.setControllers([
            ControllerSettings(deck: 1, input: nil, output: nil),
            ControllerSettings(deck: 2, input: nil, output: nil),
        ]))
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.coordinator.status.controllers.map(\.deck) == [1, 2])
        #expect(rig.midi.connected == [Rig.lc6000.id, unitB.id])
    }

    @Test("An imported profile from the pipe reaches the Coordinator: Play moves to its new note")
    func setProfilesFromThePipe() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        var mapping = try Mapping.bundledDefault()
        mapping.notes.buttons["play"] = 60
        let pipe = EventPipe()

        pipe.producer.send(.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: mapping)]))
        pipe.producer.midi(.noteOn(channel: 0, note: 60, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)

        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)]))
    }

    @Test("The demo runs the running profile: a mapping imported before it shows in the demo (#98)")
    func demoRunsTheImportedProfile() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        var mapping = try Mapping.bundledDefault()
        mapping.notes.buttons["play"] = 60
        let pipe = EventPipe()
        let seen = Seen()

        pipe.producer.send(.setProfiles([ControllerProfile(id: "custom", name: "My LC6000", deviceHints: ["LC6000"], mapping: mapping)]))
        pipe.producer.demo(on: true)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, onStatus: { seen.append($0) }, makeDemo: Self.demoMaker(rig))
            .run(pipe.events)

        #expect(seen.values.last?.demo == true)
        #expect(seen.values.last?.controllers.first?.profile == "My LC6000")
    }
}

/// The subscription check (#211) judges the DJ's real Syndicate. During the demo the bridge talks to a simulated one,
/// so the demo's status reports nothing missing.
@Suite("Demo and the subscription check")
struct DemoSubscriptionTests {
    @Test("Demo on, past the Resend answer window: no missing subscriptions, no 'no deck data'")
    func demoReportsNothingMissing() throws {
        let rig = try Rig()
        let demo = EngineTests.demoMaker(rig)(try ControllerProfile.bundled()[0])
        demo.start()
        for step in 1...40 {
            rig.clock.now = Double(step) * 0.1
            demo.tick()
        }
        #expect(demo.status.demo == true)
        #expect(demo.status.missingSubscriptions == [])
        #expect(demo.status.noDeckData == false)
    }
}
