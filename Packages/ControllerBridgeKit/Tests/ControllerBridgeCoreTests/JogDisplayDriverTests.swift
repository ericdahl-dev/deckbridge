import Foundation
@testable import ControllerBridgeCore
import Testing

/// The jog display driver (#165): hello, one image upload at a time into alternating slots, the newest content
/// winning, a refusal or timeout logged once with no retry storm, and goodbye.
@Suite("Jog display driver")
struct JogDisplayDriverTests {
    final class FakePort: JogDisplayPort, @unchecked Sendable {
        var controller: [[UInt8]] = []
        var wd: [[UInt8]] = []
        /// Whether the unit's WD port is there (#305).
        var isAttached = true
        func sendController(_ bytes: [UInt8]) { controller.append(bytes) }
        func sendWD(_ bytes: [UInt8]) { wd.append(bytes) }
    }

    static let accepted: [UInt8] = [0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x0F, 0x00, 0x01, 0x00, 0xF7]
    static let refused: [UInt8] = [0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x0F, 0x00, 0x01, 0x06, 0xF7]
    static let committed: [UInt8] = [0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x10, 0x00, 0x00, 0xF7]

    /// A 1×1 "image" per content: its deck number as the red channel, so each content's upload differs.
    static func render(_ content: JogDisplayContent) -> [UInt8] { [UInt8(content.deck), 0, 0, 255] }

    final class DriverRig {
        let port = FakePort(), clock = Rig.FakeClock(), log = Rig.FakeLog()
        lazy var driver = JogDisplayDriver(port: port, clock: clock, log: log, size: 1, render: JogDisplayDriverTests.render)
    }

    static func upload(deck: Int, slot: UInt8) -> JogDisplay.Upload {
        JogDisplay.Upload(image: JogImage.forUnit(rgba: render(JogDisplayContent(deck: deck, color: [255, 0, 0])), width: 1, height: 1), slot: slot)
    }

    /// Accepts every ack the current upload needs, then commits.
    static func complete(_ rig: DriverRig, acks: Int) {
        for _ in 0..<acks { rig.driver.reply(accepted) }
        rig.driver.reply(committed)
    }

    @Test("Connect says hello on the Controller port, then sends the first content's upload to slot 1 at once")
    func connectUploads() {
        let rig = DriverRig()
        rig.driver.connect()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        let upload = Self.upload(deck: 1, slot: 1)
        #expect(rig.port.controller == JogDisplay.hello)
        #expect(rig.port.wd == upload.start + upload.body)
    }

    @Test("Once every ack is in, it finishes (identity, commit); once committed, it shows slot 1")
    func finishThenShow() {
        let rig = DriverRig()
        rig.driver.connect()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        let upload = Self.upload(deck: 1, slot: 1)
        rig.port.wd.removeAll()
        for _ in 0..<upload.expectedAcks { rig.driver.reply(Self.accepted) }
        #expect(rig.port.wd == upload.finish)
        rig.driver.reply(Self.committed)
        #expect(rig.port.wd == upload.finish + [upload.show])
    }

    @Test("Content that changes during an upload waits; only the newest goes next, into slot 2, as soon as slot 1 shows")
    func newestWins() {
        let rig = DriverRig()
        rig.driver.connect()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        rig.driver.show(JogDisplayContent(deck: 2, color: [255, 0, 0]))
        rig.driver.show(JogDisplayContent(deck: 3, color: [255, 0, 0]))
        let first = Self.upload(deck: 1, slot: 1)
        rig.port.wd.removeAll()
        Self.complete(rig, acks: first.expectedAcks)
        // Slot 1 shows deck 1, and deck 3's upload starts at once into slot 2; deck 2 never goes.
        let next = Self.upload(deck: 3, slot: 2)
        #expect(rig.port.wd == first.finish + [first.show] + next.start + next.body)
    }

    @Test("The same content again sends nothing")
    func sameContent() {
        let rig = DriverRig()
        rig.driver.connect()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        Self.complete(rig, acks: Self.upload(deck: 1, slot: 1).expectedAcks)
        rig.port.wd.removeAll()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        rig.driver.tick()
        #expect(rig.port.wd == [])
    }

    @Test("A refusal is logged once and stops that upload; nothing is retried until the content changes")
    func refusal() {
        let rig = DriverRig()
        rig.driver.connect()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        rig.driver.reply(Self.refused)
        rig.driver.reply(Self.refused)
        rig.port.wd.removeAll()
        rig.clock.now = 30
        rig.driver.tick()
        #expect(rig.port.wd == [])
        #expect(rig.log.lines == ["The jog display refused the image (ack 06); it keeps what it showed"])
        rig.driver.show(JogDisplayContent(deck: 2, color: [255, 0, 0]))
        rig.driver.tick()
        #expect(rig.port.wd.first == [0x90, 0x01, 0x00])
    }

    @Test("No answer within 5 s: logged once, and the next content can go")
    func timeout() {
        let rig = DriverRig()
        rig.driver.connect()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        rig.clock.now = 4.9
        rig.driver.tick()
        #expect(rig.log.lines == [])
        rig.clock.now = 5.0
        rig.driver.tick()
        rig.clock.now = 9
        rig.driver.tick()
        // Where it stopped, for the hardware check: the slot, and how many of the upload's acks came (0C, 0D, 0E: 3).
        #expect(rig.log.lines == ["The jog display didn't answer the upload to slot 1 (0 of 3 acks); it keeps what it showed"])
    }

    @Test("A timeout after some acks says how many came")
    func timeoutAfterAcks() {
        let rig = DriverRig()
        rig.driver.connect()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        rig.driver.reply(JogDisplayDriverTests.accepted)
        rig.clock.now = 5.0
        rig.driver.tick()
        #expect(rig.log.lines == ["The jog display didn't answer the upload to slot 1 (1 of 3 acks); it keeps what it showed"])
    }

    @Test("Disconnect says goodbye on the Controller port, once")
    func goodbye() {
        let rig = DriverRig()
        rig.driver.connect()
        rig.port.controller.removeAll()
        rig.driver.disconnect()
        rig.driver.disconnect()
        #expect(rig.port.controller == [JogDisplay.goodbye])
    }

    @Test("Before connect, content is only remembered: nothing is sent")
    func notConnected() {
        let rig = DriverRig()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        rig.driver.tick()
        #expect(rig.port.wd == [])
        #expect(rig.port.controller == [])
    }
}

/// What the driver did, as typed events, for the Diagnostics simulator (#221): the same facts as the bytes on WD.
@Suite("Jog display events")
struct JogDisplayEventTests {
    @Test("An upload, its acks and commit, the show, the marker and the play light are each an event")
    func events() {
        let port = JogDisplayDriverTests.FakePort(), log = Rig.FakeLog()
        let driver = JogDisplayDriver(port: port, clock: Rig.FakeClock(), log: log, size: 1, render: JogDisplayDriverTests.render)
        var events: [JogDisplayEvent] = []
        driver.onEvent = { events.append($0) }
        driver.connect()
        driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        let upload = JogDisplayDriverTests.upload(deck: 1, slot: 1)
        let bytes = upload.body.reduce(0) { $0 + $1.count }
        for _ in 0..<upload.expectedAcks { driver.reply(JogDisplayDriverTests.accepted) }
        driver.reply(JogDisplayDriverTests.committed)
        driver.needle(2048)
        driver.playLight(true)
        #expect(events == [
            .connected,
            .uploadStarted(slot: 1, content: JogDisplayContent(deck: 1, color: [255, 0, 0]), bytes: bytes),
            .shown(slot: 1),
            .needle(pitchBend: 2048),
            .playLight(true),
        ])
    }

    @Test("A refusal is an event with its status")
    func refused() {
        let driver = JogDisplayDriver(port: JogDisplayDriverTests.FakePort(), clock: Rig.FakeClock(), log: Rig.FakeLog(), size: 1,
                                      render: JogDisplayDriverTests.render)
        var events: [JogDisplayEvent] = []
        driver.onEvent = { events.append($0) }
        driver.connect()
        driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        driver.reply(JogDisplayDriverTests.refused)
        #expect(events.last == .failed(refusal: 0x06))
    }
}
