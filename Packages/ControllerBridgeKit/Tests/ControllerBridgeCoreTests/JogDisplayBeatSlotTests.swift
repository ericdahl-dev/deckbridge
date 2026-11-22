import Foundation
@testable import ControllerBridgeCore
import Testing

/// The master beat lit on the LC6000 itself (#215), at the Coordinator seam: each content goes up four times, into
/// slots 1–4 with beat 1–4 lit, and each master beat shows its slot. Proven on hardware in #165: a slot swap is one
/// 14-byte message, clean at 8 a second and more.
@Suite("Jog display beat slots")
struct JogDisplayBeatSlotTests {
    typealias Port = JogDisplayDriverTests.FakePort

    /// What the beat renderer was asked to draw, in order.
    final class Drawn: @unchecked Sendable {
        var beats: [Int] = []
        var contents: [JogDisplayContent] = []
    }

    static func attach(_ rig: Rig) -> (Port, Drawn) {
        let port = Port(), drawn = Drawn()
        let driver = JogDisplayDriver(port: port, clock: rig.clock, log: rig.log, size: 1, renderBeat: { content, beat in
            drawn.beats.append(beat)
            drawn.contents.append(content)
            return [UInt8(beat), 0, 0, 255]
        }) { _ in [0, 0, 0, 255] }
        rig.coordinator.attachJogDisplay(driver)
        rig.coordinator.setJogDisplay(enabled: true)
        return (port, drawn)
    }

    /// The slot of each upload in `port`'s WD messages: 0E's first payload byte.
    static func uploadSlots(_ port: Port) -> [UInt8] {
        port.wd.filter { $0.count > 9 && $0[6] == 0x0E }.map { $0[9] }
    }

    /// Answers the upload in flight (every ack, then the commit), keeping what the driver sends next.
    static func answer(_ rig: Rig, _ port: Port) {
        let acks = port.wd.filter { $0.count > 6 && [0x0C, 0x0D, 0x0E].contains($0[6]) }.count
        port.wd.removeAll()
        for _ in 0..<acks { rig.coordinator.jogDisplayReply(JogDisplayDriverTests.accepted) }
        rig.coordinator.jogDisplayReply(JogDisplayDriverTests.committed)
    }

    /// Runs the four uploads; returns their slots.
    static func uploadAll(_ rig: Rig, _ port: Port) -> [UInt8] {
        var slots: [UInt8] = []
        for _ in 0..<4 {
            slots += uploadSlots(port)
            answer(rig, port)
        }
        return slots
    }

    static func clock(_ rig: Rig, _ beat: Int) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Header/Clock", [.int(Int32(beat))]))
    }

    @Test("A new content goes up four times, into slots 3, 4, 1, 2 with that beat lit: the master's beat (3) first")
    func fourUploads() throws {
        let rig = try Rig()
        let (port, drawn) = Self.attach(rig)
        Self.clock(rig, 3)
        rig.coordinator.start()
        #expect(Self.uploadAll(rig, port) == [3, 4, 1, 2])
        // The last four drawn are the unit's (the simulator's preview draws before the hello).
        #expect(Array(drawn.beats.suffix(4)) == [3, 4, 1, 2])
        #expect(Set(drawn.contents.map(\.deck)) == [1])
    }

    /// The show messages (0A) in `port`'s WD messages, as their slots; not the 0A that leads an upload (before its 0C).
    static func shows(_ port: Port) -> [UInt8] {
        port.wd.indices.filter { index in
            let message = port.wd[index]
            guard message.count > 11, message[6] == 0x0A else { return false }
            let next = index + 1 < port.wd.count ? port.wd[index + 1] : []
            return !(next.count > 6 && next[6] == 0x0C)
        }.map { port.wd[$0][11] }
    }

    @Test("While the four go up, only the master's beat (3) is shown, again after each upload; then each beat shows its slot, with mask 0D, and uploads nothing")
    func showPerBeat() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        Self.clock(rig, 3)
        rig.coordinator.start()
        var shown: [UInt8] = []
        for _ in 0..<4 {
            Self.answer(rig, port)
            shown += Self.shows(port)
        }
        #expect(shown == [3, 3, 3, 3])   // each upload starts by showing blank (slot 6): the beat's slot comes back after it
        port.wd.removeAll()
        for beat in [4, 1, 2, 3] { Self.clock(rig, beat) }
        #expect(port.wd == [4, 1, 2, 3].map { JogDisplay.show(slot: $0) })
    }

    @Test("A track load uploads all four again, from the beat now (2); an old-track slot isn't shown on its beat until it's redone")
    func reloadOnContentChange() throws {
        let rig = try Rig()
        let (port, drawn) = Self.attach(rig)
        Self.clock(rig, 1)
        rig.coordinator.start()
        _ = Self.uploadAll(rig, port)
        Self.clock(rig, 2)
        port.wd.removeAll()
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        var slots = Self.uploadSlots(port)
        Self.clock(rig, 3)                        // slot 3 still holds the old track: the screen holds
        var shown = Self.shows(port)
        for _ in 0..<4 {
            Self.answer(rig, port)
            slots += Self.uploadSlots(port)
            shown += Self.shows(port)
        }
        #expect(slots == [2, 3, 4, 1])
        #expect(shown == [3, 3, 3])               // slot 3, once it holds the new track, and again after each later upload
        #expect(drawn.contents.suffix(4).allSatisfy { $0.title != nil })
    }

    @Test("No commit reply (seen twice on hardware, #165): 0.3 s after the last ack the slot counts as stored and the next upload goes")
    func noCommitReply() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        Self.clock(rig, 1)
        rig.coordinator.start()
        let acks = port.wd.filter { $0.count > 6 && [0x0C, 0x0D, 0x0E].contains($0[6]) }.count
        port.wd.removeAll()
        for _ in 0..<acks { rig.coordinator.jogDisplayReply(JogDisplayDriverTests.accepted) }
        rig.clock.now += 0.29
        rig.coordinator.tick()
        #expect(Self.uploadSlots(port) == [])
        rig.clock.now += 0.02
        rig.coordinator.tick()
        #expect(Self.shows(port) == [1])
        #expect(Self.uploadSlots(port) == [2])
    }

    @Test("Switch off: through a start, a load, master beats and ticks, beat mode sends nothing to either port")
    func offSendsNothing() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        rig.coordinator.setJogDisplay(enabled: false)
        rig.coordinator.start()
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        for step in 1...16 {
            Self.clock(rig, (step - 1) % 4 + 1)
            rig.clock.now = Double(step) * 0.25
            rig.coordinator.tick()
        }
        #expect(port.controller == [])
        #expect(port.wd == [])
    }

    @Test("With the master stopped (no new beat), the screen ends on the beat's slot after a load, not on the blank each upload starts with")
    func endsOnTheBeatNotBlank() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        Self.clock(rig, 2)
        rig.coordinator.start()
        _ = Self.uploadAll(rig, port)
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        var lastShow: UInt8?
        for _ in 0..<4 {
            Self.answer(rig, port)
            lastShow = port.wd.filter { $0.count > 11 && $0[6] == 0x0A }.last?[11] ?? lastShow
        }
        #expect(lastShow == 2)
    }

    @Test("A beat never shows a slot in the middle of an upload (a show between the chunks can spoil it: ack 06); it waits for the upload to be stored")
    func noShowMidUpload() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        Self.clock(rig, 1)
        rig.coordinator.start()
        Self.answer(rig, port)               // slot 1 stored and shown; slot 2's upload is now on the wire
        let acks = port.wd.filter { $0.count > 6 && [0x0C, 0x0D, 0x0E].contains($0[6]) }.count
        port.wd.removeAll()
        for beat in [2, 3, 4, 1] { Self.clock(rig, beat) }   // the bar comes round to beat 1, whose slot is ready
        #expect(port.wd.filter { $0.count > 11 && $0[6] == 0x0A && $0[9] == 0x0D } == [])
        for _ in 0..<acks { rig.coordinator.jogDisplayReply(JogDisplayDriverTests.accepted) }
        rig.coordinator.jogDisplayReply(JogDisplayDriverTests.committed)   // slot 2 stored: beat 1's slot comes back
        #expect(Self.shows(port).first == 1)
    }

    @Test("After a layer change, nothing goes up (the new deck is on the unit, #424) and each master beat shows its slot")
    func beatsAfterLayerChange() throws {
        let rig = try Rig()
        let (port, drawn) = Self.attach(rig)
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: LayersTests.lc6000Layers
        ))
        Self.clock(rig, 1)
        // Every layer's deck goes up after connect (#424): deck 1's four, then decks 2-4.
        var rounds = 0
        while !Self.uploadSlots(port).isEmpty, rounds < 40 { Self.answer(rig, port); rounds += 1 }
        #expect(Set(drawn.contents.map(\.deck)) == [1, 2, 3, 4])
        port.wd.removeAll()
        LayersTests.switchLayer(rig, from: 1, to: 2)
        #expect(Self.uploadSlots(port).isEmpty)   // deck 2 is already on the unit
        port.wd.removeAll()
        for beat in [2, 3, 4, 1] { Self.clock(rig, beat) }
        // Deck 2's own slots (#424): beat B is slot 4 + B.
        #expect(Self.shows(port) == [6, 7, 8, 5])
    }

    @Test("A layer change while the master plays, with the new deck's TrackInfo arriving mid-upload: once the uploads settle, every beat shows its slot")
    func beatsAfterLayerChangeWhilePlaying() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: LayersTests.lc6000Layers
        ))
        Self.clock(rig, 1)
        _ = Self.uploadAll(rig, port)
        LayersTests.switchLayer(rig, from: 1, to: 2)
        var beat = 1
        var rounds = 0
        // Answer uploads as they come, a master beat between each, and deck 2's track arriving after the first.
        while !Self.uploadSlots(port).isEmpty, rounds < 20 {
            Self.answer(rig, port)
            beat = beat % 4 + 1
            Self.clock(rig, beat)
            if rounds == 0 { rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 2, title: "Night Drive")) }
            rounds += 1
        }
        port.wd.removeAll()
        var expected: [UInt8] = []
        // Deck 2's own slots (#424): beat B is slot 4 + B.
        for _ in 0..<4 { beat = beat % 4 + 1; expected.append(UInt8(beat + 4)); Self.clock(rig, beat) }
        #expect(Self.shows(port) == expected)
    }

    @Test("A beat upload that stalls (1 of 3 acks, seen on hardware after a deck change) is tried again, the rest still go up, and every beat shows")
    func stalledUploadRetried() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        Self.clock(rig, 1)
        rig.coordinator.start()
        Self.answer(rig, port)                    // slot 1 stored; slot 2 on the wire
        port.wd.removeAll()
        rig.coordinator.jogDisplayReply(JogDisplayDriverTests.accepted)   // 1 of 3 acks, then nothing
        rig.clock.now += 5
        rig.coordinator.tick()
        #expect(Self.uploadSlots(port) == [2])   // slot 2 again
        var slots: [UInt8] = [2]
        for _ in 0..<3 {
            Self.answer(rig, port)
            slots += Self.uploadSlots(port)
        }
        #expect(slots == [2, 3, 4])
        Self.answer(rig, port)
        port.wd.removeAll()
        for beat in [2, 3, 4, 1] { Self.clock(rig, beat) }
        #expect(Self.shows(port) == [2, 3, 4, 1])
    }

    @Test("A slot that stalls three times in a row is given up on, logged, and the rest still go up: no endless retries")
    func stalledUploadGivenUp() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        Self.clock(rig, 1)
        rig.coordinator.start()
        Self.answer(rig, port)                    // slot 1 stored; slot 2 on the wire
        var tries = 0
        while Self.uploadSlots(port) == [2], tries < 10 {
            tries += 1
            port.wd.removeAll()
            rig.clock.now += 5
            rig.coordinator.tick()
        }
        #expect(tries == 3)
        #expect(Self.uploadSlots(port) == [3])
    }

    /// The 0A that leads each upload (the one just before its 0C) in `port`'s WD messages: its mask and slot.
    static func leads(_ port: Port) -> [[UInt8]] {
        port.wd.indices.filter { $0 > 0 && port.wd[$0].count > 6 && port.wd[$0][6] == 0x0C }
            .map { port.wd[$0 - 1] }.filter { $0.count > 11 && $0[6] == 0x0A }.map { [$0[9], $0[11]] }
    }

    @Test("No loading graphic and no blank (#424): each upload leads with the slot on screen, the first with its own slot")
    func leadsHoldTheScreen() throws {
        let rig = try Rig()
        let (port, _) = Self.attach(rig)
        Self.clock(rig, 3)
        rig.coordinator.start()
        var leads: [[UInt8]] = []
        for _ in 0..<4 {
            leads += Self.leads(port).prefix(1)
            Self.answer(rig, port)
        }
        // Slot 3 (the master's beat) goes up first, leading with itself; once stored it's on screen, and leads the rest.
        #expect(leads == [[0x0D, 0x03], [0x0D, 0x03], [0x0D, 0x03], [0x0D, 0x03]])
    }
}
