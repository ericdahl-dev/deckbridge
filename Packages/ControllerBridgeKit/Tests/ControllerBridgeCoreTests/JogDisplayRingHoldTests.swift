import Foundation
@testable import ControllerBridgeCore
import Testing

/// The ring holds while the jog display uploads (#422). On hardware, the LC6000's platter ring LED (Controller note 40)
/// lit through an LED repaint made the display drop uploads after one ack (1 stall in ~6-10 uploads); kept at 0 while
/// the uploads ran, 1 stall in ~480. The driver says when uploads run; the Coordinator holds the ring dark meanwhile.
@Suite("Jog display ring hold")
struct JogDisplayRingHoldTests {
    typealias Port = JogDisplayDriverTests.FakePort

    /// A beat-mode driver on its own, as the app runs it.
    static func driver(_ rig: Rig, _ port: Port) -> JogDisplayDriver {
        JogDisplayDriver(port: port, clock: rig.clock, log: rig.log, size: 1,
                         renderBeat: { _, beat in [UInt8(beat), 0, 0, 255] }) { _ in [0, 0, 0, 255] }
    }

    /// Answers the driver's upload in flight: every ack, then the commit.
    static func answer(_ driver: JogDisplayDriver, _ port: Port) {
        let acks = port.wd.filter { $0.count > 6 && [0x0C, 0x0D, 0x0E].contains($0[6]) }.count
        port.wd.removeAll()
        for _ in 0..<acks { driver.reply(JogDisplayDriverTests.accepted) }
        driver.reply(JogDisplayDriverTests.committed)
    }

    @Test("Uploading from a new content until its fourth slot is stored, and not before or after")
    func uploadingSpansTheFour() throws {
        let rig = try Rig()
        let port = Port()
        let driver = Self.driver(rig, port)
        driver.connect()
        #expect(!driver.uploading)
        driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        var during: [Bool] = []
        for _ in 0..<4 {
            during.append(driver.uploading)
            Self.answer(driver, port)
        }
        #expect(during == [true, true, true, true])
        #expect(!driver.uploading)
    }

    @Test("A unit that never answers: still uploading while slots are retried, not once every slot is given up on")
    func givenUp() throws {
        let rig = try Rig()
        let port = Port()
        let driver = Self.driver(rig, port)
        driver.connect()
        driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        // Each of the 4 slots is tried 3 times, 5 s each: 60 s in all.
        for second in 1...59 {
            rig.clock.now = Double(second)
            driver.tick()
        }
        #expect(driver.uploading)
        rig.clock.now = 61
        driver.tick()
        #expect(!driver.uploading)
    }

    @Test("Disconnected mid-upload: not uploading")
    func disconnected() throws {
        let rig = try Rig()
        let port = Port()
        let driver = Self.driver(rig, port)
        driver.connect()
        driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        #expect(driver.uploading)
        driver.disconnect()
        #expect(!driver.uploading)
    }

    static let lc6000 = MIDIEndpoint(id: 1001, name: "DENON LC6000 PRIME")
    static let wd = MIDIEndpoint(id: 1005, name: "DENON LC6000 PRIME WD")

    /// The LC6000 with its WD port, so its profile owns the display, and a beat-mode driver on a fake port; deck 1 loaded.
    static func owned() throws -> (ProfileMatchingTests.ProfileRig, Port) {
        let rig = ProfileMatchingTests.ProfileRig(profiles: try ControllerProfile.bundled(), sources: [lc6000, wd])
        let port = Port()
        rig.coordinator.attachJogDisplay(JogDisplayDriver(port: port, clock: Rig.FakeClock(), log: rig.log, size: 1,
                                                          renderBeat: { _, beat in [UInt8(beat), 0, 0, 255] }) { _ in [0, 0, 0, 255] })
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        return (rig, port)
    }

    /// Every velocity sent to the ring (note 40) on the LC6000's output, in order.
    static func ring(_ rig: ProfileMatchingTests.ProfileRig) -> [UInt8] {
        let out = rig.midi.outputs[lc6000.id + 1000]?.sent ?? []
        return out.compactMap { if case .noteOn(_, 40, let velocity) = $0 { velocity } else { nil } }
    }

    /// Answers the upload in flight through the Coordinator, as the app's pipe does.
    static func answer(_ rig: ProfileMatchingTests.ProfileRig, _ port: Port) {
        let acks = port.wd.filter { $0.count > 6 && [0x0C, 0x0D, 0x0E].contains($0[6]) }.count
        port.wd.removeAll()
        for _ in 0..<acks { rig.coordinator.jogDisplayReply(JogDisplayDriverTests.accepted) }
        rig.coordinator.jogDisplayReply(JogDisplayDriverTests.committed)
    }

    @Test("Turning the display on: the ring goes to 0 while the four uploads run, and nothing lights it until they're done; then its deck color")
    func ringHeldWhileUploading() throws {
        let (rig, port) = try Self.owned()
        let lit = try #require(Self.ring(rig).last)
        #expect(lit > 0)   // loaded: the ring shows deck 1's color
        let before = Self.ring(rig).count
        rig.coordinator.setJogDisplay(enabled: true)
        var during: [UInt8] = []
        for _ in 0..<4 {
            during = Array(Self.ring(rig).dropFirst(before))
            #expect(during.last == 0)
            #expect(!during.contains { $0 > 0 })
            Self.answer(rig, port)
        }
        #expect(Self.ring(rig).last == lit)
    }

    /// #533: the smooth pulse never lights the ring during an upload (#422), beats or not.
    @Test("With the color message and the smooth pulse on, master beats during the uploads send the ring nothing but dark")
    func pulseHeldWhileUploading() throws {
        var profiles = try ControllerProfile.bundled()
        for index in profiles.indices { profiles[index].mapping.leds.beatPulse = .beat }
        let rig = ProfileMatchingTests.ProfileRig(profiles: profiles, sources: [Self.lc6000, Self.wd])
        let port = Port()
        rig.coordinator.attachJogDisplay(JogDisplayDriver(port: port, clock: Rig.FakeClock(), log: rig.log, size: 1,
                                                          renderBeat: { _, beat in [UInt8(beat), 0, 0, 255] }) { _ in [0, 0, 0, 255] })
        rig.coordinator.start()
        rig.coordinator.setColorMessages(true)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        let output = try #require(rig.midi.outputs[Self.lc6000.id + 1000])
        rig.coordinator.setJogDisplay(enabled: true)
        func last() -> [UInt8]? { output.colors.last { $0.note == 40 }.map { [$0.red, $0.green, $0.blue] } }
        #expect(last() == [0, 0, 0])
        for step in 0..<3 {
            rig.coordinator.feedback(OSCMessage("/Syndicate/Header/Clock", [.int(Int32(step + 1))]))
            rig.coordinator.tick()
            #expect(last() == [0, 0, 0], "beat \(step + 1)")
            Self.answer(rig, port)
        }
    }

    @Test("A layer switch to deck 2 while images still go up: no ring lit from the switch until the last upload is done; then deck 2's color")
    func layerSwitchHoldsRing() throws {
        let (rig, port) = try Self.owned()
        let out = MIDIEndpoint(id: Self.lc6000.id + 1000, name: Self.lc6000.name)
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Self.lc6000, output: out)], layers: LayersTests.lc6000Layers))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        rig.coordinator.setJogDisplay(enabled: true)
        for _ in 0..<4 { Self.answer(rig, port) }
        #expect(rig.coordinator.status.controllers.count == 4)   // one entry per layer
        let before = Self.ring(rig).count
        // The unit's layer handover to layer 2: note 51 at 0 on ch1, then 127 on ch2.
        rig.coordinator.midi(.noteOn(channel: 0, note: 51, velocity: 0), source: Self.lc6000.id)
        rig.coordinator.midi(.noteOn(channel: 1, note: 51, velocity: 127), source: Self.lc6000.id)
        // The other decks' images are still going up (#424): the ring stays dark until the last one is stored.
        var rounds = 0
        while port.wd.contains(where: { $0.count > 6 && $0[6] == 0x0C }), rounds < 40 {
            let since = Array(Self.ring(rig).dropFirst(before))
            #expect(!since.contains { $0 > 0 })
            Self.answer(rig, port)
            rounds += 1
        }
        #expect(rounds > 0)
        #expect((Self.ring(rig).last ?? 0) > 0)
    }
}
