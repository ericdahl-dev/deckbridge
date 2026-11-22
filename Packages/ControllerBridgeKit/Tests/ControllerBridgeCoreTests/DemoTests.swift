import ControllerBridgeCore
import Testing

/// The built-in demo (#64): a real Coordinator driven by an in-process demo controller and an in-memory Syndicate, so
/// App Review can see the bridge work with no hardware and no network. Expected OSC and LEDs are literals. Tempo
/// values are worked from the LC6000 pitch formula (MSB × 128 / 16383 × 2 − 1), rounded to 5 places as the bridge sends
/// them (#17), not from the code.
@Suite("Demo")
struct DemoTests {
    static let deck = "/Syndicate/Deck/1/"
    static let resend = OSCMessage("/Syndicate/Feedback/Resend", [.int(1)])

    final class DemoRig {
        let clock = Rig.FakeClock()
        let leds = Rig.FakeOutput()
        let session: DemoSession

        init() throws {
            session = DemoSession(profile: try ControllerProfile.bundled()[0], clock: clock, log: Rig.FakeLog(), ledOutput: leds)
            session.start()
        }

        /// Ticks every 10 ms, as the app does, up to `time`.
        func run(to time: Double) {
            while clock.now + 0.01 <= time + 1e-9 {
                clock.now += 0.01
                session.tick()
            }
        }

        /// What Syndicate was sent, without the Resends.
        var sent: [OSCMessage] { session.sentToSyndicate.filter { $0 != DemoTests.resend } }

        /// The latest velocity of each LED note.
        var led: [UInt8: UInt8] {
            var out: [UInt8: UInt8] = [:]
            for case let .noteOn(_, note, velocity) in leds.sent { out[note] = velocity }
            return out
        }
    }

    @Test("Starting the demo connects the demo controller, and the in-memory Syndicate answers the Resend: live, loaded, two cues")
    func start() throws {
        let rig = try DemoRig()
        #expect(rig.session.sentToSyndicate == [Self.resend])
        #expect(rig.session.status.demo)
        #expect(rig.session.status.feedback == .live)
        #expect(rig.session.status.controllers.map(\.connected) == [true])
        // Play dim (stopped), Cue lit (loaded and stopped), pads 1-2 in cue colors red 48 and orange 56, ring 11.
        #expect([rig.led[1], rig.led[2], rig.led[32], rig.led[33], rig.led[34], rig.led[40]] == [1, 127, 48, 56, 0, 48])
    }

    @Test("The first seconds of the script: Play, a pitch fader move from center, a jog nudge, as literal OSC")
    func firstSeconds() throws {
        let rig = try DemoRig()
        rig.run(to: 0.6)
        #expect(rig.sent == [OSCMessage(Self.deck + "PlayPause", [.int(1)])])
        #expect(rig.led[1] == 127)   // the in-memory Syndicate answered Playing 1

        rig.run(to: 3.5)
        #expect(rig.sent == [
            OSCMessage(Self.deck + "PlayPause", [.int(1)]),
            OSCMessage(Self.deck + "TempoSlider", [.float(0)]),
            OSCMessage(Self.deck + "TempoSlider", [.float(0.06256)]),
            OSCMessage(Self.deck + "TempoSlider", [.float(0.12507)]),
            OSCMessage(Self.deck + "TempoSlider", [.float(0.18757)]),
            OSCMessage(Self.deck + "TempoSlider", [.float(0.25008)]),
            OSCMessage(Self.deck + "PhaseBend", [.int(1)]),
            OSCMessage(Self.deck + "PhaseBend", [.int(0)]),
        ])
    }

    @Test("The fader picks up at once from center, because the demo deck reports tempo 0 (a pickup change mustn't break the demo)")
    func faderPicksUpAtOnce() throws {
        let rig = try DemoRig()
        rig.run(to: 1.0)
        #expect(rig.sent.last == OSCMessage(Self.deck + "TempoSlider", [.float(0)]))
    }

    @Test("At 6 s the demo stops the deck, and at 8.5 s the script starts again from the top")
    func pausesAndLoops() throws {
        let rig = try DemoRig()
        rig.run(to: 6.1)
        #expect(rig.sent.last == OSCMessage(Self.deck + "PlayPause", [.int(1)]))
        #expect(rig.led[1] == 1)     // Playing 0 came back
        let count = rig.sent.count
        rig.run(to: 8.6)
        #expect(rig.sent.count == count + 1)
        #expect(rig.sent.last == OSCMessage(Self.deck + "PlayPause", [.int(1)]))
        #expect(rig.led[1] == 127)
    }

    @Test("The demo's feedback never drops: beats while playing, and answered probes while stopped")
    func staysLive() throws {
        let rig = try DemoRig()
        for second in 1...40 {
            rig.run(to: Double(second))
            #expect(rig.session.status.feedback == .live)
        }
    }

    @Test("Stopping the demo releases what it holds: a jog nudge held at stop gets its PhaseBend 0")
    func stopReleases() throws {
        let rig = try DemoRig()
        rig.run(to: 3.05)
        #expect(rig.sent.last == OSCMessage(Self.deck + "PhaseBend", [.int(1)]))
        rig.session.stop()
        #expect(rig.sent.last == OSCMessage(Self.deck + "PhaseBend", [.int(0)]))
        let count = rig.session.sentToSyndicate.count
        rig.run(to: 5)
        #expect(rig.session.sentToSyndicate.count == count)
    }

    @Test("The demo's controller runs on the device named Demo controller, so Settings' picker and the capture window offer it (#200)")
    func demoNamesItsDevice() throws {
        let rig = try DemoRig()
        #expect(rig.session.status.controllers.first?.device == "Demo controller")
    }
}

/// The demo feeds the jog display simulator too (#29: the App Store shot and App Review see it): a made-up track's
/// TrackInfo, the deck's BPM, and a BarRamp each beat, so the preview shows a title and its needle turns with the bar.
@Suite("Demo and the jog display simulator")
struct DemoJogDisplayTests {
    final class Events: @unchecked Sendable { var list: [JogDisplayEvent] = [] }

    static func run(to time: Double, firmware: DisplayFirmware = .denon) throws -> [JogDisplayEvent] {
        let rig = try DemoTests.DemoRig()
        let events = Events()
        let preview = JogDisplayDriver(port: nil, clock: rig.clock, log: Rig.FakeLog(), size: 1) { _ in [0, 0, 0, 255] }
        preview.onEvent = { events.list.append($0) }
        rig.session.coordinator.attachJogDisplay(preview)
        rig.session.coordinator.setDisplayFirmware(firmware)
        rig.run(to: time)
        return events.list
    }

    @Test("The demo deck shows a made-up track: Demo Track by DeckBridge, Am, 120 BPM, a plain track")
    func track() throws {
        let previews = try Self.run(to: 1).compactMap { if case .preview(let content) = $0 { content } else { nil } }
        let shown = try #require(previews.last)
        #expect([shown.title, shown.artist, shown.key, shown.playerType] == ["Demo Track", "DeckBridge", "Am", "track"])
        #expect(shown.bpm == 120)
    }

    @Test("While it plays, the needle turns (several positions in a second) and the master beat runs")
    func needleAndBeat() throws {
        let events = try Self.run(to: 3)
        let needles = Set(events.compactMap { if case .deckMarker(1, let pitchBend) = $0 { pitchBend } else { nil } })
        #expect(needles.count >= 8)
        #expect(events.contains { if case .masterBeat = $0 { true } else { false } })
    }

    @Test("Firmware set to Custom: the demo deck's drawn preview, with its title, its needle moving while it plays (#465)")
    func drawn() throws {
        let states = try Self.run(to: 3, firmware: .custom).compactMap { if case .drawnPreview(let state) = $0 { state } else { nil } }
        let deck1 = states.filter { $0.deck?.number == 1 }
        #expect(deck1.last?.texts[.title] == Array("Demo Track".utf8))
        #expect(Set(deck1.compactMap(\.needle)).count >= 8)
    }
}
