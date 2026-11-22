import Foundation
@testable import ControllerBridgeCore
import Testing

/// After a power cycle (#606): the top panel may miss the hello, so it's sent again until it answers; and the display
/// chip's own boot sequence covers the host's images until it says ready (its first 10 reply), so the show then goes
/// again. Only messages the app already sends, newly timed.
@Suite("Jog display after a power cycle")
struct JogDisplayPowerCycleTests {
    typealias DriverRig = JogDisplayDriverTests.DriverRig

    /// Ticks the driver every 0.1 s up to `until`, noting when each hello pair went out.
    static func run(_ rig: DriverRig, from start: Double = 0, until end: Double) -> [Double] {
        var times: [Double] = []
        var t = start
        while t <= end + 1e-9 {
            rig.clock.now = t
            let before = rig.port.controller.count
            rig.driver.tick()
            if rig.port.controller.count > before {
                #expect(Array(rig.port.controller.dropFirst(before)) == JogDisplay.hello)
                times.append((t * 10).rounded() / 10)
            }
            t += 0.1
        }
        return times
    }

    @Test("No answer to the hello: the same hello pair again at 1, 3, 7, 15 and 31 s, then never")
    func helloAgain() {
        let rig = DriverRig()
        rig.driver.connect()
        #expect(Self.run(rig, until: 120) == [1, 3, 7, 15, 31])
    }

    @Test("A stalled tick (the Mac asleep) sends one hello pair, not the missed ones in a burst; the gaps go on from it")
    func noCatchUpBurst() {
        let rig = DriverRig()
        rig.driver.connect()
        #expect(Self.run(rig, until: 0.5).isEmpty)
        #expect(Self.run(rig, from: 10, until: 40) == [10, 12, 16, 24, 40])
    }

    @Test("The top panel answers (after the 1 s hello): no more; a goodbye stops them too, and a reconnect starts over")
    func answerStops() {
        let rig = DriverRig()
        rig.driver.connect()
        #expect(Self.run(rig, until: 2) == [1])
        rig.driver.helloAnswered()
        #expect(Self.run(rig, from: 2.1, until: 60).isEmpty)

        let other = DriverRig()
        other.driver.connect()
        _ = Self.run(other, until: 2)
        other.driver.disconnect()
        #expect(Self.run(other, from: 2.1, until: 60).isEmpty)
        other.port.controller.removeAll()
        other.driver.connect()
        #expect(Self.run(other, from: 60, until: 120) == [61, 63, 67, 75, 91])
    }

    final class Lines: @unchecked Sendable { var list: [String] = [] }

    static func traced(_ rig: DriverRig) -> Lines {
        let lines = Lines()
        rig.driver.trace = { _, text in if !text.hasPrefix("CTL out") && !text.hasPrefix("WD") && !text.hasPrefix("event") { lines.list.append(text) } }
        return lines
    }

    @Test("The trace says when the hello wasn't answered, each re-send, and what stopped them")
    func helloTrace() {
        let rig = DriverRig()
        let lines = Self.traced(rig)
        rig.driver.connect()
        _ = Self.run(rig, until: 3.5)
        rig.driver.helloAnswered()
        rig.driver.helloAnswered()
        #expect(lines.list == [
            "jog display: no answer to the hello in 0.5 s: sending it again at 1, 3, 7, 15, 31 s",
            "jog display: hello again (1 of 5)",
            "jog display: hello again (2 of 5)",
            "jog display: the top panel answered the hello 3.5 s after it: no more re-sends",
        ])

        let gone = DriverRig()
        let goneLines = Self.traced(gone)
        gone.driver.connect()
        _ = Self.run(gone, until: 1.5)
        gone.driver.disconnect()
        #expect(goneLines.list.last == "jog display: hello re-sends stop: goodbye")

        let silent = DriverRig()
        let silentLines = Self.traced(silent)
        silent.driver.connect()
        _ = Self.run(silent, until: 120)
        #expect(silentLines.list.suffix(2) == [
            "jog display: hello again (5 of 5)",
            "jog display: the top panel never answered the hello (5 re-sends, 31.5 s): no more",
        ])
        #expect(silent.log.lines.filter { $0.contains("never answered the hello") }.count == 1)
    }

    @Test("Answered in time: no trace line about the hello at all")
    func answeredInTime() {
        let rig = DriverRig()
        let lines = Self.traced(rig)
        rig.driver.connect()
        rig.clock.now = 0.02
        rig.driver.helloAnswered()
        _ = Self.run(rig, from: 0.1, until: 60)
        #expect(lines.list.isEmpty)
    }

    // MARK: Through the Coordinator: the answer is the top panel's ch16 note 55 on, on the display owner's port.

    typealias Port = JogDisplayDriverTests.FakePort
    typealias CoordinatorRig = ProfileMatchingTests.ProfileRig

    /// The LC6000 owning the display, its driver on a clock the test moves; the display on.
    static func owned() throws -> (CoordinatorRig, Port, Rig.FakeClock, JogDisplayDriver) {
        let rig = ProfileMatchingTests.ProfileRig(profiles: try ControllerProfile.bundled(),
                                                  sources: [JogDisplayRingHoldTests.lc6000, JogDisplayRingHoldTests.wd])
        let port = Port(), clock = Rig.FakeClock()
        let driver = JogDisplayDriver(port: port, clock: clock, log: rig.log, size: 1,
                                      renderBeat: { _, beat in [UInt8(beat), 0, 0, 255] }) { _ in [0, 0, 0, 255] }
        rig.coordinator.attachJogDisplay(driver)
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        rig.coordinator.setJogDisplay(enabled: true)
        return (rig, port, clock, driver)
    }

    /// Hello pairs sent from `start` to `end`, ticking the Coordinator every 0.1 s.
    static func hellos(_ rig: CoordinatorRig, _ port: Port, _ clock: Rig.FakeClock, from start: Double, until end: Double) -> Int {
        port.controller.removeAll()
        var t = start
        while t <= end + 1e-9 {
            clock.now = t
            rig.clock.now = t
            rig.coordinator.tick()
            t += 0.1
        }
        return port.controller.filter { $0 == JogDisplay.hello[1] }.count
    }

    @Test("The LC6000's ch16 note 55 on at 127 stops the re-sends; on another channel, at 0, or from another port it doesn't")
    func answerThroughCoordinator() throws {
        let lc6000 = JogDisplayRingHoldTests.lc6000.id, iac = MIDIEndpoint.ID(1000)
        for (event, source, stops) in [(MIDIEvent.noteOn(channel: 15, note: 55, velocity: 127), lc6000, true),
                                       (.noteOn(channel: 0, note: 55, velocity: 127), lc6000, false),
                                       (.noteOn(channel: 15, note: 55, velocity: 0), lc6000, false),
                                       (.noteOn(channel: 15, note: 55, velocity: 127), iac, false)] {
            let (rig, port, clock, _) = try Self.owned()
            #expect(port.controller.contains(JogDisplay.hello[1]))
            clock.now = 0.2
            rig.coordinator.midi(event, source: source)
            #expect(Self.hellos(rig, port, clock, from: 0.3, until: 40) == (stops ? 0 : 5), "\(event) from \(source)")
        }
    }

    // MARK: A: the display chip's first 10 reply since the hello is "ready": the show goes again.

    static let ready = JogDisplayDriverTests.committed

    /// Connected, deck 1 uploaded into slot 1 with every ack, stored by the commit grace (no 10 reply: the chip is still
    /// booting) and shown; WD's record cleared.
    static func shownByGrace(_ rig: DriverRig) -> JogDisplay.Upload {
        rig.driver.connect()
        rig.driver.helloAnswered()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        let upload = JogDisplayDriverTests.upload(deck: 1, slot: 1)
        for _ in 0..<upload.expectedAcks { rig.driver.reply(JogDisplayDriverTests.accepted) }
        rig.clock.now = 0.4
        rig.driver.tick()
        #expect(rig.port.wd.last == upload.show)
        rig.port.wd.removeAll()
        return upload
    }

    @Test("Ready with nothing in flight: the last show once more, at once; a second 10 reply sends nothing")
    func readyShowsAgain() {
        let rig = DriverRig()
        let lines = Self.traced(rig)
        let upload = Self.shownByGrace(rig)
        rig.clock.now = 22
        rig.driver.reply(Self.ready)
        #expect(rig.port.wd == [upload.show])
        rig.driver.reply(Self.ready)
        rig.driver.tick()
        #expect(rig.port.wd == [upload.show])
        #expect(lines.list == ["jog display: the display said ready (its first 10 reply since the hello): show slot 1 sent again"])
    }

    @Test("Ready in the middle of an upload: nothing between its chunks; its own show, once stored, is the one")
    func readyMidUpload() {
        let rig = DriverRig()
        let lines = Self.traced(rig)
        _ = Self.shownByGrace(rig)
        rig.driver.show(JogDisplayContent(deck: 2, color: [255, 0, 0]))
        let second = JogDisplayDriverTests.upload(deck: 2, slot: 2)
        rig.port.wd.removeAll()
        rig.driver.reply(Self.ready)
        rig.driver.tick()
        #expect(rig.port.wd.isEmpty)
        JogDisplayDriverTests.complete(rig, acks: second.expectedAcks)
        #expect(rig.port.wd == second.finish + [second.show])
        #expect(lines.list == ["jog display: the display said ready (its first 10 reply since the hello): "
                               + "a show went out after it, nothing sent again"])
    }

    @Test("Ready mid-upload, and the upload then fails: the last show goes again once it's over")
    func readyThenFail() {
        let rig = DriverRig()
        let lines = Self.traced(rig)
        let first = Self.shownByGrace(rig)
        rig.driver.show(JogDisplayContent(deck: 2, color: [255, 0, 0]))
        rig.port.wd.removeAll()
        rig.driver.reply(Self.ready)
        rig.clock.now = 6
        rig.driver.tick()
        #expect(rig.port.wd == [first.show])
        #expect(lines.list.last == "jog display: the display said ready (its first 10 reply since the hello): show slot 1 sent again")
    }

    @Test("The commit of an upload as the first 10 reply (a chip already booted): its show only, nothing more")
    func readyIsTheCommit() {
        let rig = DriverRig()
        rig.driver.connect()
        rig.driver.helloAnswered()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        let upload = JogDisplayDriverTests.upload(deck: 1, slot: 1)
        rig.port.wd.removeAll()
        JogDisplayDriverTests.complete(rig, acks: upload.expectedAcks)
        rig.driver.reply(Self.ready)
        rig.driver.tick()
        #expect(rig.port.wd == upload.finish + [upload.show])
    }

    @Test("Nothing shown since this hello (a reconnect forgets the last one): ready sends nothing, and says so")
    func readyNothingShown() {
        let rig = DriverRig()
        let lines = Self.traced(rig)
        _ = Self.shownByGrace(rig)
        rig.driver.disconnect()
        rig.driver.connect()
        rig.driver.helloAnswered()
        rig.clock.now = 10
        rig.driver.tick()                    // the reconnect's upload times out
        rig.port.wd.removeAll()
        rig.driver.reply(Self.ready)
        rig.driver.tick()
        #expect(rig.port.wd.isEmpty)
        #expect(lines.list.last == "jog display: the display said ready (its first 10 reply since the hello): nothing shown yet, nothing sent")
    }

    @Test("Drawn mode (Custom answered after an image was shown): a 10 reply sends no show")
    func readyWhileDrawing() {
        let rig = DriverRig()
        _ = Self.shownByGrace(rig)
        rig.driver.displayFirmware = .custom
        rig.driver.reply(DrawnDisplayHandshakeTests.answer)
        rig.port.wd.removeAll()
        rig.driver.reply(Self.ready)
        rig.driver.tick()
        #expect(!rig.port.wd.contains { $0.count > 6 && $0[6] == 0x0A })
    }

    static let neverReady = "jog display: the display never said ready in 60 s (no 10 reply since the hello); nothing sent for it"

    @Test("No 10 reply 60 s after the first 10 since the hello: said once, to the trace and the log; nothing sent for it")
    func neverReady() {
        let rig = DriverRig()
        let lines = Self.traced(rig)
        _ = Self.shownByGrace(rig)
        for t in stride(from: 1.0, through: 59.9, by: 0.1) { rig.clock.now = t; rig.driver.tick() }
        #expect(!lines.list.contains(Self.neverReady))
        for t in stride(from: 60.0, through: 200, by: 0.1) { rig.clock.now = t; rig.driver.tick() }
        #expect(lines.list.filter { $0 == Self.neverReady }.count == 1)
        #expect(rig.log.lines.filter { $0.contains("never said ready") }.count == 1)
        #expect(rig.port.wd.isEmpty)
    }

    @Test("No 10 ever sent (nothing to show), or the display said ready: no line")
    func readyOrNotAsked() {
        let quiet = DriverRig()
        let quietLines = Self.traced(quiet)
        quiet.driver.connect()
        quiet.driver.helloAnswered()
        for t in stride(from: 1.0, through: 100, by: 1) { quiet.clock.now = t; quiet.driver.tick() }
        #expect(!quietLines.list.contains(Self.neverReady))

        let ready = DriverRig()
        let readyLines = Self.traced(ready)
        _ = Self.shownByGrace(ready)
        ready.driver.reply(Self.ready)
        for t in stride(from: 1.0, through: 100, by: 1) { ready.clock.now = t; ready.driver.tick() }
        #expect(!readyLines.list.contains(Self.neverReady))
    }

    // MARK: A re-sent hello answered: the LEDs painted again (#426), once per connect.

    static let answer = MIDIEvent.noteOn(channel: 15, note: 55, velocity: 127)

    @Test("A re-sent hello answered: every LED painted at start goes out again, once, and the trace says so")
    func repaintAfterLateAnswer() throws {
        let (rig, port, clock, _) = try Self.owned()
        final class Box: @unchecked Sendable { var list: [String] = [] }
        let lines = Box()
        rig.coordinator.trace = { category, text in if category == .jogDisplay { lines.list.append(text) } }
        let painted = Set(JogDisplayHelloRepaintTests.sent(rig).map(\.note))
        _ = Self.hellos(rig, port, clock, from: 0.1, until: 1.5)
        let before = JogDisplayHelloRepaintTests.sent(rig).count
        rig.coordinator.midi(Self.answer, source: JogDisplayRingHoldTests.lc6000.id)
        let after = Array(JogDisplayHelloRepaintTests.sent(rig).dropFirst(before))
        #expect(Set(after.map(\.note)).isSuperset(of: painted))
        #expect(lines.list.contains("jog display: a re-sent hello was answered: the LEDs painted again"))
        // Mid-upload, so the ring stays at 0 (#422).
        #expect(after.last { $0.note == 40 }?.velocity == 0)
        let again = JogDisplayHelloRepaintTests.sent(rig).count
        rig.coordinator.midi(Self.answer, source: JogDisplayRingHoldTests.lc6000.id)
        #expect(JogDisplayHelloRepaintTests.sent(rig).count - again < painted.count, "not a second repaint")
    }

    @Test("The first hello answered in time: no repaint beyond today's after-hello one")
    func noRepaintInTime() throws {
        let (rig, _, clock, _) = try Self.owned()
        clock.now = 0.02
        let before = JogDisplayHelloRepaintTests.sent(rig).count
        rig.coordinator.midi(Self.answer, source: JogDisplayRingHoldTests.lc6000.id)
        let painted = Set(JogDisplayHelloRepaintTests.sent(rig).prefix(before).map(\.note))
        #expect(JogDisplayHelloRepaintTests.sent(rig).count - before < painted.count)
    }

    // MARK: The pin: a power cycle through the Coordinator sends only what the app sent before #606.

    @Test("A power cycle, end to end: only today's messages go out on either port and the LEDs; never 0F, 72, 78, 79, 7A, 7C or 7F")
    func onlyTodaysBytes() throws {
        let (rig, port, clock, driver) = try Self.owned()
        let lc6000 = JogDisplayRingHoldTests.lc6000.id
        let ledsAtStart = Set(JogDisplayHelloRepaintTests.sent(rig).map(\.note))
        let output = try #require(rig.midi.outputs[lc6000 + 1000])
        let writesAtStart = output.writes
        final class Box: @unchecked Sendable { var list: [String] = [] }
        let lines = Box()
        rig.coordinator.trace = { category, text in if category == .jogDisplay { lines.list.append(text) } }
        driver.trace = rig.coordinator.trace
        var wd: [[UInt8]] = [], controller: [[UInt8]] = []
        var t = 0.0
        while t <= 70 + 1e-9 {
            clock.now = t
            rig.clock.now = t
            // The booting chip acks every upload message, answers no 10 until 22 s, and the top panel answers the third hello.
            let acks = port.wd.filter { $0.count > 6 && [0x0C, 0x0D, 0x0E].contains($0[6]) }.count
            wd += port.wd; controller += port.controller
            port.wd.removeAll(); port.controller.removeAll()
            for _ in 0..<acks { rig.coordinator.jogDisplayReply(JogDisplayDriverTests.accepted) }
            if abs(t - 3.2) < 1e-6 { rig.coordinator.midi(Self.answer, source: lc6000) }
            if abs(t - 22) < 1e-6 { rig.coordinator.jogDisplayReply(Self.ready) }
            rig.coordinator.tick()
            t += 0.1
        }
        wd += port.wd; controller += port.controller

        let identity: [UInt8] = [0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]
        for message in wd {
            if message.first == 0xF0, message != identity {
                #expect(Array(message[1...5]) == [0x00, 0x02, 0x0B, 0x7F, 0x10])
                #expect([0x0A, 0x0C, 0x0D, 0x0E, 0x10].contains(message[6]), "WD cmd \(message[6])")
            } else if message.first != 0xF0 {
                #expect(message.first == 0xE0 || Array(message.prefix(2)) == [0x90, 0x01], "WD \(message)")
            }
        }
        for message in controller { #expect(JogDisplay.hello.contains(message) || message == JogDisplay.goodbye) }
        #expect(controller.filter { $0 == JogDisplay.hello[1] }.count == 3, "the hello and two re-sends, then the answer")
        let forbidden: Set<UInt8> = [0x0F, 0x72, 0x78, 0x79, 0x7A, 0x7C, 0x7F]
        for message in wd + controller where message.first == 0xF0 && message.count > 6 && message[1...3] == [0x00, 0x02, 0x0B] {
            #expect(!forbidden.contains(message[6]))
        }
        // The late repaint is today's LEDs again: no note the start didn't paint.
        #expect(Set(JogDisplayHelloRepaintTests.sent(rig).map(\.note)).isSubset(of: ledsAtStart))
        // Every LED write, note-ons and Denon's color messages (#541) alike, is one the start already made.
        let later = output.writes.dropFirst(writesAtStart.count)
        #expect(!later.isEmpty)
        for write in later { #expect(writesAtStart.contains(write), "LED write \(write)") }
        // Each new path ran: the re-sends, the late repaint, and the show after ready.
        #expect(lines.list.contains("jog display: a re-sent hello was answered: the LEDs painted again"))
        #expect(lines.list.contains { $0.hasPrefix("jog display: the display said ready") && !$0.contains("nothing shown") })
    }
}
