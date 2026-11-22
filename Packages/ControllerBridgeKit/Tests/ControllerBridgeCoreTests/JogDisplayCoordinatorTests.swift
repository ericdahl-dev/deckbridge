import Foundation
@testable import ControllerBridgeCore
import Testing

/// The jog display at the Coordinator seam (#165): the display shows the deck in front, in its deck color, on connect,
/// on a layer change and on a deck-color change, and says goodbye when the unit goes. Syndicate's factory deck colors
/// (#123): deck 1 red, deck 2 yellow.
@Suite("Jog display at the Coordinator")
struct JogDisplayCoordinatorTests {
    typealias Port = JogDisplayDriverTests.FakePort

    /// What each upload showed, read back from the fake renderer's calls.
    final class Shown: @unchecked Sendable { var contents: [JogDisplayContent] = [] }

    static func attach(_ rig: Rig) -> (Port, Shown) {
        let port = Port(), shown = Shown()
        rig.coordinator.attachJogDisplay(JogDisplayDriver(port: port, clock: rig.clock, log: rig.log, size: 1) { content in
            shown.contents.append(content)
            return [UInt8(content.deck), 0, 0, 255]
        })
        rig.coordinator.setJogDisplay(enabled: true)
        return (port, shown)
    }

    @Test("Off by default: attached, through a start, a layer change, a load, playing and ticks, nothing goes to either port")
    func offByDefault() throws {
        let rig = try Rig()
        let port = Port()
        rig.coordinator.attachJogDisplay(JogDisplayDriver(port: port, clock: rig.clock, log: rig.log, size: 1) { _ in [0, 0, 0, 255] })
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: LayersTests.lc6000Layers
        ))
        LayersTests.switchLayer(rig, from: 1, to: 2)
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 2))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Header/Clock", [.int(1)]))
        for step in 1...20 { rig.clock.now = Double(step) * 0.05; rig.coordinator.tick() }
        #expect(port.controller == [])
        #expect(port.wd == [])
    }

    @Test("Turned off while showing: goodbye, then nothing more; on again: hello")
    func turnOff() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        rig.coordinator.start()
        port.controller.removeAll()
        rig.coordinator.setJogDisplay(enabled: false)
        #expect(port.controller == [JogDisplay.goodbye])
        port.wd.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        rig.clock.now = 1
        rig.coordinator.tick()
        #expect(port.wd == [])
        rig.coordinator.setJogDisplay(enabled: true)
        #expect(port.controller == [JogDisplay.goodbye] + JogDisplay.hello)
    }

    /// Answers the upload in flight: every ack, then the commit.
    static func answer(_ rig: Rig, _ port: Port) {
        let acks = port.wd.filter { $0.count > 6 && [0x0C, 0x0D, 0x0E].contains($0[6]) }.count
        for _ in 0..<acks { rig.coordinator.jogDisplayReply(JogDisplayDriverTests.accepted) }
        rig.coordinator.jogDisplayReply(JogDisplayDriverTests.committed)
        port.wd.removeAll()
    }

    @Test("Connect says hello and shows deck 1 in red")
    func connect() throws {
        let rig = try Rig()
        let (port, shown) = Self.attach(rig)
        rig.coordinator.start()
        #expect(port.controller == JogDisplay.hello)
        #expect(shown.contents == [JogDisplayContent(deck: 1, color: [255, 0, 0])])
    }

    @Test("Switching to layer 2 shows deck 2 in yellow, once the first image is up")
    func layerChange() throws {
        let rig = try Rig()
        let (port, shown) = Self.attach(rig)
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: LayersTests.lc6000Layers
        ))
        LayersTests.switchLayer(rig, from: 1, to: 2)
        Self.answer(rig, port)
        #expect(shown.contents.last == JogDisplayContent(deck: 2, color: [255, 255, 0]))
    }

    @Test("Syndicate changing deck 1's color redraws it")
    func colorChange() throws {
        let rig = try Rig()
        let (port, shown) = Self.attach(rig)
        rig.coordinator.start()
        Self.answer(rig, port)
        // Cue palette slot 1, deck 1's color (#123), now blue.
        rig.coordinator.feedback(OSCMessage("/Syndicate/ColorPalette", [.int(1), .int(0), .int(0), .int(255)]))
        #expect(shown.contents.last == JogDisplayContent(deck: 1, color: [0, 0, 255]))
    }

    @Test("Stop says goodbye")
    func stop() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        rig.coordinator.start()
        port.controller.removeAll()
        rig.coordinator.stop()
        #expect(port.controller == [JogDisplay.goodbye])
    }

    @Test("Unplugging the unit says goodbye; plugging it back says hello again")
    func unplug() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        rig.coordinator.start()
        port.controller.removeAll()
        rig.midi.sources.removeAll { $0.id == Rig.lc6000.id }
        rig.coordinator.devicesChanged()
        #expect(port.controller == [JogDisplay.goodbye])
        rig.midi.sources.append(Rig.lc6000)
        rig.coordinator.devicesChanged()
        #expect(port.controller == [JogDisplay.goodbye] + JogDisplay.hello)
    }
}

/// The marker and the play light on the WD port (#165), at the Coordinator seam. Pitch bend on ch1 is E0 lsb msb;
/// the play light is note 1 on ch1. The marker is the deck's own needle (the user's pick), from its BarRamp and BPM.
/// Worked by hand at 120 BPM (a 2 s bar): a quarter-second after BarRamp 0 is 1/8 turn, 2048 (E0 00 10).
@Suite("Jog marker at the Coordinator")
struct JogMarkerCoordinatorTests {
    static func started() throws -> (Rig, JogDisplayDriverTests.FakePort) {
        let rig = try Rig()
        let (port, _) = JogDisplayCoordinatorTests.attach(rig)
        rig.coordinator.start()
        JogDisplayCoordinatorTests.answer(rig, port)
        port.wd.removeAll()
        return (rig, port)
    }

    static func bends(_ port: JogDisplayDriverTests.FakePort) -> [[UInt8]] { port.wd.filter { $0.first == 0xE0 } }
    static func lights(_ port: JogDisplayDriverTests.FakePort) -> [[UInt8]] { port.wd.filter { $0.count == 3 && $0[0] == 0x90 && $0[1] == 1 } }

    static func feed(_ rig: Rig, _ path: String, _ argument: OSCArgument) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/" + path, [argument]))
    }

    static func tick(_ rig: Rig, at time: Double) {
        rig.clock.now = time
        rig.coordinator.tick()
    }

    @Test("Playing, the needle is the deck's phase: BarRamp 0 at 120 BPM is 0, then 2048 a quarter-second on")
    func deckNeedle() throws {
        let (rig, port) = try Self.started()
        Self.feed(rig, "Deck/1/Playing", .int(1))
        Self.feed(rig, "Deck/1/BPM", .float(120))
        Self.feed(rig, "Deck/1/BarRamp", .float(0))
        Self.tick(rig, at: 0)
        Self.tick(rig, at: 0.25)
        #expect(Self.bends(port) == [[0xE0, 0x00, 0x00], [0xE0, 0x00, 0x10]])
    }

    @Test("The master clock doesn't move the needle: Header/Clock 3 with no BarRamp leaves it at 0")
    func masterDoesntMoveIt() throws {
        let (rig, port) = try Self.started()
        Self.feed(rig, "Deck/1/Playing", .int(1))
        Self.feed(rig, "Header/BPM", .float(120))
        Self.feed(rig, "Header/Clock", .int(3))
        Self.tick(rig, at: 0.2)
        #expect(Self.bends(port) == [[0xE0, 0x00, 0x00]])
    }

    /// The needle keeps a send schedule (#558) on the shared live cadence, 20 ms since #605 (#592's stall was power, not
    /// the rate): two 10 ms ticks, so every step is the same. At 120 BPM the needle is t × 8192, whole steps: sends at 0,
    /// 0.02, 0.04, 0.06 and 0.08 s are 0, 163, 327, 491 and 655.
    @Test("At most 50 a second, on a schedule: ticks every 10 ms send at 0, 0.02, 0.04, 0.06 and 0.08 s")
    func rateLimit() throws {
        let (rig, port) = try Self.playingAt120()
        for step in 0...9 { Self.tick(rig, at: Double(step) * 0.01) }
        #expect(Self.bends(port) == [[0xE0, 0x00, 0x00], [0xE0, 0x23, 0x01], [0xE0, 0x47, 0x02], [0xE0, 0x6B, 0x03],
                                     [0xE0, 0x0F, 0x05]])
    }

    @Test("An even cadence: over a second of 10 ms ticks, every gap between needle sends is exactly 20 ms")
    func evenGaps() throws {
        let (rig, port) = try Self.playingAt120()
        var sentAt: [Int] = []
        for step in 0..<100 {
            let before = Self.bends(port).count
            Self.tickRamped(rig, at: Double(step) * 0.01)
            if Self.bends(port).count > before { sentAt.append(step) }
        }
        #expect(sentAt.count == 50)
        #expect(zip(sentAt, sentAt.dropFirst()).allSatisfy { $1 - $0 == 2 })
    }

    /// A tick at `time` with Syndicate's BarRamp at the deck's true phase then (a bar is 2 s at 120 BPM), so the needle
    /// keeps moving: it runs on at most a beat past the last ramp.
    static func tickRamped(_ rig: Rig, at time: Double) {
        rig.clock.now = time
        Self.feed(rig, "Deck/1/BarRamp", .float(Float((time / 2).truncatingRemainder(dividingBy: 1))))
        rig.coordinator.tick()
    }

    static func playingAt120() throws -> (Rig, JogDisplayDriverTests.FakePort) {
        let (rig, port) = try Self.started()
        Self.feed(rig, "Deck/1/Playing", .int(1))
        Self.feed(rig, "Deck/1/BPM", .float(120))
        Self.feed(rig, "Deck/1/BarRamp", .float(0))
        return (rig, port)
    }

    @Test("A second of 10 ms ticks sends the needle 50 times, the cap")
    func fullRate() throws {
        let (rig, port) = try Self.playingAt120()
        for step in 0..<100 { Self.tickRamped(rig, at: Double(step) * 0.01) }
        #expect(Self.bends(port).count == 50)
    }

    @Test("Late ticks (the timer's leeway): ticks 5 ms late every other time still send 50 a second (the on-time ticks are the due ones)")
    func lateTicks() throws {
        let (rig, port) = try Self.playingAt120()
        for step in 0..<100 { Self.tickRamped(rig, at: Double(step) * 0.01 + (step % 2 == 1 ? 0.005 : 0)) }
        #expect(Self.bends(port).count == 50)
    }

    @Test("After a stall the schedule restarts: no burst to catch up, the next send is 20 ms on")
    func noBurstAfterStall() throws {
        let (rig, port) = try Self.playingAt120()
        Self.tickRamped(rig, at: 0)
        Self.tickRamped(rig, at: 1)
        let before = Self.bends(port).count
        Self.tickRamped(rig, at: 1.01)
        #expect(Self.bends(port).count == before)
        Self.tickRamped(rig, at: 1.02)
        #expect(Self.bends(port).count == before + 1)
    }

    @Test("The platter never moves the needle (the user's pick for v1.1): touched and turned, a playing deck's needle stays on its BarRamp")
    func platterLeavesNeedle() throws {
        let (rig, port) = try Self.started()
        Self.feed(rig, "Deck/1/Playing", .int(1))
        Self.feed(rig, "Deck/1/BPM", .float(120))
        Self.feed(rig, "Deck/1/BarRamp", .float(0))
        Self.tick(rig, at: 0)
        // Touch the top, turn a quarter (platter 1000 then 1900), while Syndicate's ramp keeps coming.
        rig.coordinator.midi(.noteOn(channel: 0, note: 40, velocity: 127), source: Rig.lc6000.id)
        for (msb, lsb) in [(UInt8(7), UInt8(104)), (14, 108)] {
            rig.coordinator.midi(.controlChange(channel: 0, controller: 17, value: msb), source: Rig.lc6000.id)
            rig.coordinator.midi(.controlChange(channel: 0, controller: 49, value: lsb), source: Rig.lc6000.id)
        }
        rig.clock.now = 0.05
        Self.feed(rig, "Deck/1/BarRamp", .float(0.5))
        Self.tick(rig, at: 0.1)
        // The ramp's 0.5, run on 0.05 s at 120 BPM: 0.525 of a turn, 8601 (E0 19 43); the platter's quarter is ignored.
        #expect(Self.bends(port).last == [0xE0, 0x19, 0x43])
        #expect(!Self.bends(port).contains([0xE0, 0x00, 0x20]))
    }

    @Test("Paused, a turn of the platter (900 counts) doesn't move the needle: the seek moves the deck's BarRamp, which does")
    func pausedPlatter() throws {
        let (rig, port) = try Self.started()
        Self.feed(rig, "Deck/1/BPM", .float(120))
        Self.feed(rig, "Deck/1/BarRamp", .float(0.5))
        Self.tick(rig, at: 0.2)
        // Platter at 1000, then 1900: 900 counts forward (CC 17 then CC 49).
        for (msb, lsb) in [(UInt8(7), UInt8(104)), (14, 108)] {
            rig.coordinator.midi(.controlChange(channel: 0, controller: 17, value: msb), source: Rig.lc6000.id)
            rig.coordinator.midi(.controlChange(channel: 0, controller: 49, value: lsb), source: Rig.lc6000.id)
        }
        Self.tick(rig, at: 0.3)
        #expect(Self.bends(port) == [])
    }

    @Test("Playing then paused, the needle stops where it was: BarRamp 0, paused a quarter-second on, it holds 1/8 (2048), platter or not")
    func pauseFreezes() throws {
        let (rig, port) = try Self.started()
        Self.feed(rig, "Deck/1/Playing", .int(1))
        Self.feed(rig, "Deck/1/BPM", .float(120))
        Self.feed(rig, "Deck/1/BarRamp", .float(0))
        Self.tick(rig, at: 0.25)
        #expect(Self.bends(port).last == [0xE0, 0x00, 0x10])
        Self.feed(rig, "Deck/1/Playing", .int(0))
        port.wd.removeAll()
        for (msb, lsb) in [(UInt8(7), UInt8(104)), (14, 108)] {
            rig.coordinator.midi(.controlChange(channel: 0, controller: 17, value: msb), source: Rig.lc6000.id)
            rig.coordinator.midi(.controlChange(channel: 0, controller: 49, value: lsb), source: Rig.lc6000.id)
        }
        Self.tick(rig, at: 1)
        #expect(Self.bends(port).allSatisfy { $0 == [0xE0, 0x00, 0x10] })
    }


    @Test("The play light: 127 while playing; loaded and paused, it blinks every half-second")
    func playLight() throws {
        let (rig, port) = try Self.started()
        Self.feed(rig, "Deck/1/Loaded", .int(1))
        Self.feed(rig, "Deck/1/Playing", .int(1))
        Self.tick(rig, at: 0.1)
        #expect(Self.lights(port) == [[0x90, 0x01, 0x7F]])
        Self.feed(rig, "Deck/1/Playing", .int(0))
        Self.tick(rig, at: 0.2)
        Self.tick(rig, at: 0.5)
        Self.tick(rig, at: 1.0)
        #expect(Self.lights(port) == [[0x90, 0x01, 0x7F], [0x90, 0x01, 0x00], [0x90, 0x01, 0x7F]])
    }
}

/// What the display shows comes from Syndicate's TrackInfo (#165): title, artist, key, BPM and player type, from the
/// real capture's argument order <title> <artist> <key> <bpm> <length> <bars> <beats> <player_type>. Redrawn only when
/// it changes.
@Suite("Jog display content")
struct JogDisplayContentTests {
    static func trackInfo(deck: Int = 1, title: String = "Daybreak", key: String = "A#m", bpm: Float = 128) -> OSCMessage {
        OSCMessage("/Syndicate/Deck/\(deck)/TrackInfo", [
            .string(title), .string("Bill Hamel, Jeremus"), .string(key), .float(bpm), .float(428.5), .int(229), .int(914), .string("track"),
        ])
    }

    static let daybreak = JogDisplayContent(deck: 1, color: [255, 0, 0], title: "Daybreak", artist: "Bill Hamel, Jeremus",
                                            key: "A#m", bpm: 128, playerType: "track")

    @Test("A loaded track's TrackInfo shows its title, artist, key, BPM and player type")
    func trackInfo() throws {
        let rig = try Rig()
        let (port, shown) = JogDisplayCoordinatorTests.attach(rig)
        rig.coordinator.start()
        JogDisplayCoordinatorTests.answer(rig, port)
        rig.coordinator.feedback(Self.trackInfo())
        #expect(shown.contents.last == Self.daybreak)
    }

    @Test("The same TrackInfo again draws nothing new; a key change redraws")
    func onlyOnChange() throws {
        let rig = try Rig()
        let (port, shown) = JogDisplayCoordinatorTests.attach(rig)
        rig.coordinator.start()
        JogDisplayCoordinatorTests.answer(rig, port)
        rig.coordinator.feedback(Self.trackInfo())
        JogDisplayCoordinatorTests.answer(rig, port)
        let drawn = shown.contents.count
        rig.coordinator.feedback(Self.trackInfo())
        rig.coordinator.tick()
        #expect(shown.contents.count == drawn)
        rig.coordinator.feedback(Self.trackInfo(key: "Bm"))
        #expect(shown.contents.last?.key == "Bm")
    }

    @Test("Another deck's TrackInfo doesn't change what deck 1's display shows")
    func otherDeck() throws {
        let rig = try Rig()
        let (port, shown) = JogDisplayCoordinatorTests.attach(rig)
        rig.coordinator.start()
        JogDisplayCoordinatorTests.answer(rig, port)
        rig.coordinator.feedback(Self.trackInfo(deck: 2))
        #expect(shown.contents == [JogDisplayContent(deck: 1, color: [255, 0, 0])])
    }
}

/// The jog display's switch and the unit's answers come through the pipe, in order with everything else (#165).
@Suite("Jog display through the pipe")
struct JogDisplayPipeTests {
    @Test("setJogDisplay(enabled: true) from the pipe says hello; a reply from the pipe reaches the driver")
    func throughThePipe() async throws {
        let rig = try Rig()
        let port = JogDisplayDriverTests.FakePort()
        rig.coordinator.attachJogDisplay(JogDisplayDriver(port: port, clock: rig.clock, log: rig.log, size: 1) { _ in [0, 0, 0, 255] })
        rig.coordinator.start()
        let pipe = EventPipe()
        pipe.producer.send(.setJogDisplay(enabled: true))
        pipe.producer.jogDisplayReply(JogDisplayDriverTests.refused)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)
        #expect(port.controller == JogDisplay.hello)
        #expect(rig.log.lines.contains("The jog display refused the image (ack 06); it keeps what it showed"))
    }
}

/// Settings' "Show the deck on the jog display" (#165): off by default and in settings saved before it, and rebased
/// like the other switches.
@Suite("Jog display setting")
struct JogDisplaySettingTests {
    @Test("On by default for new settings (v1.1, after the hardware check); settings saved before it keep it off")
    func onByDefault() throws {
        let defaults = BridgeSettings.defaults(from: try Mapping.bundledDefault())
        #expect(defaults.jogDisplay == true)
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
        saved["jogDisplay"] = nil
        let old = try JSONDecoder().decode(BridgeSettings.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(old.jogDisplay == false)
    }

    @Test("A draft that turned it on keeps it on across a rebase")
    func rebased() throws {
        let base = BridgeSettings.defaults(from: try Mapping.bundledDefault())
        var draft = base
        draft.jogDisplay = true
        #expect(BridgeSettings.rebased(draft: draft, base: base, onto: base).jogDisplay == true)
    }
}


/// Every deck's needle for the simulator, and the master beat for the ring (#165, the user's pick): the needle is each
/// deck's own phase, the lit segment is the master's beat, the same on every deck.
@Suite("Jog needles per deck and the master beat")
struct JogNeedleEventTests {
    final class Events: @unchecked Sendable { var list: [JogDisplayEvent] = [] }

    static func started() throws -> (Rig, JogDisplayDriverTests.FakePort, Events) {
        let rig = try Rig()
        let port = JogDisplayDriverTests.FakePort(), events = Events()
        let driver = JogDisplayDriver(port: port, clock: rig.clock, log: rig.log, size: 1) { _ in [0, 0, 0, 255] }
        driver.onEvent = { events.list.append($0) }
        rig.coordinator.attachJogDisplay(driver)
        rig.coordinator.setJogDisplay(enabled: true)
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: LayersTests.lc6000Layers
        ))
        JogDisplayCoordinatorTests.answer(rig, port)
        port.wd.removeAll()
        events.list.removeAll()
        return (rig, port, events)
    }

    static func needles(_ events: Events) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for case let .deckMarker(deck, pitchBend) in events.list { out[deck] = pitchBend }
        return out
    }

    @Test("Decks 1 and 3 playing at their own phase: each needle reported; the unit gets only deck 1's (in front)")
    func perDeck() throws {
        let (rig, port, events) = try Self.started()
        for (deck, ramp) in [(1, 0.25), (3, 0.5)] {
            JogMarkerCoordinatorTests.feed(rig, "Deck/\(deck)/Playing", .int(1))
            JogMarkerCoordinatorTests.feed(rig, "Deck/\(deck)/BPM", .float(120))
            JogMarkerCoordinatorTests.feed(rig, "Deck/\(deck)/BarRamp", .float(Float(ramp)))
        }
        JogMarkerCoordinatorTests.tick(rig, at: 0)
        #expect(Self.needles(events) == [1: 4096, 3: 8192])
        #expect(JogMarkerCoordinatorTests.bends(port) == [[0xE0, 0x00, 0x20]])
    }

    @Test("Settings' Apply (setControllers) leaves the display on: a goodbye while the entries change, then hello again")
    func applyKeepsItOn() throws {
        let (_, port, _) = try Self.started()
        #expect(port.controller.suffix(2) == JogDisplay.hello[...])
    }

    @Test("A paused deck's needle stays where it was")
    func paused() throws {
        let (rig, _, events) = try Self.started()
        JogMarkerCoordinatorTests.feed(rig, "Deck/3/Playing", .int(1))
        JogMarkerCoordinatorTests.feed(rig, "Deck/3/BPM", .float(120))
        JogMarkerCoordinatorTests.feed(rig, "Deck/3/BarRamp", .float(0.5))
        JogMarkerCoordinatorTests.tick(rig, at: 0)
        JogMarkerCoordinatorTests.feed(rig, "Deck/3/Playing", .int(0))
        events.list.removeAll()
        JogMarkerCoordinatorTests.tick(rig, at: 0.5)
        #expect(Self.needles(events) == [:])
    }

    @Test("Every deck's play state, from Syndicate's Playing, once and then per change: not the blinking play light (#317)")
    func deckPlaying() throws {
        let (rig, _, events) = try Self.started()
        events.list.removeAll()
        JogMarkerCoordinatorTests.feed(rig, "Deck/3/Playing", .int(1))
        JogMarkerCoordinatorTests.feed(rig, "Deck/1/Track", .string("Daybreak"))
        for t in stride(from: 0.0, through: 2.0, by: 0.25) { JogMarkerCoordinatorTests.tick(rig, at: t) }
        JogMarkerCoordinatorTests.feed(rig, "Deck/3/Playing", .int(0))
        for t in stride(from: 2.25, through: 4.0, by: 0.25) { JogMarkerCoordinatorTests.tick(rig, at: t) }
        let plays = events.list.compactMap { event -> String? in
            if case .deckPlaying(let deck, let on) = event { return "\(deck) \(on)" }
            return nil
        }
        // The first tick tells the simulator every deck's state; after that, only deck 3's two changes.
        #expect(plays == ["1 false", "2 false", "3 true", "4 false", "3 false"])
    }

    @Test("Header/Clock is the master beat for every deck's ring, as an event only: nothing is sent for it")
    func masterBeat() throws {
        let (rig, port, events) = try Self.started()
        JogMarkerCoordinatorTests.feed(rig, "Header/Clock", .int(3))
        #expect(events.list.contains(.masterBeat(3)))
        #expect(port.wd == [])
    }

    // MARK: Whose display (#305)

    @Test("No WD port: no hello, no upload, nothing waited on; once the port appears, hello")
    func noWDPort() throws {
        let rig = try Rig()
        let (port, _) = JogDisplayCoordinatorTests.attach(rig)
        port.isAttached = false
        rig.coordinator.start()
        for step in 1...40 { rig.clock.now = Double(step) * 0.5; rig.coordinator.tick() }
        #expect(port.controller == [])
        #expect(port.wd == [])
        #expect(!rig.log.lines.contains { $0.contains("didn't answer") })
        port.isAttached = true
        rig.coordinator.devicesChanged()
        #expect(port.controller == JogDisplay.hello)
    }

    @Test("Two controllers, the LC6000 unplugged and plugged back: goodbye, then hello again, though the other stayed")
    func replugWithAnotherController() throws {
        let rig = try Rig()
        let (port, _) = JogDisplayCoordinatorTests.attach(rig)
        let iac = MIDIEndpoint(id: 1000, name: "IAC Bus 1")
        rig.coordinator.start()
        rig.coordinator.setControllers([
            ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out, followLayers: false),
            ControllerSettings(deck: 2, input: iac, output: nil, followLayers: false),
        ])
        port.controller.removeAll()
        rig.midi.sources.removeAll { $0.id == Rig.lc6000.id }
        port.isAttached = false
        rig.coordinator.devicesChanged()
        #expect(port.controller == [JogDisplay.goodbye])
        rig.midi.sources.append(Rig.lc6000)
        port.isAttached = true
        rig.coordinator.devicesChanged()
        #expect(port.controller == [JogDisplay.goodbye] + JogDisplay.hello)
    }

    @Test("With another controller first, the display shows the deck of the controller whose profile owns the WD port")
    func showsTheOwnersDeck() throws {
        let testPad = try ControllerProfile(decoding: ProfileTests.testPadFile())
        let pad = MIDIEndpoint(id: 1004, name: "TP-1 Pad")
        let lc6000 = MIDIEndpoint(id: 1001, name: "DENON LC6000 PRIME")
        let wd = MIDIEndpoint(id: 1005, name: "DENON LC6000 PRIME WD")
        let rig = ProfileMatchingTests.ProfileRig(profiles: try ControllerProfile.bundled() + [testPad], sources: [pad, lc6000, wd])
        let port = JogDisplayCoordinatorTests.Port(), shown = JogDisplayCoordinatorTests.Shown()
        rig.coordinator.attachJogDisplay(JogDisplayDriver(port: port, clock: Rig.FakeClock(), log: rig.log, size: 1) { content in
            shown.contents.append(content)
            return [UInt8(content.deck), 0, 0, 255]
        })
        rig.coordinator.start()
        rig.coordinator.setControllers([
            ControllerSettings(deck: 1, input: pad, output: nil, followLayers: false),
            ControllerSettings(deck: 2, input: lc6000, output: nil, followLayers: false),
        ])
        rig.coordinator.setJogDisplay(enabled: true)
        #expect(shown.contents.last?.deck == 2)
    }
}
