import Foundation
@testable import ControllerBridgeCore
import Testing

/// The debug trace (#395): what Debug builds write to os_log and to a rolling file, so an agent can read what the
/// controller, Syndicate and the jog display did without asking for a paste.
@Suite("Debug trace")
struct TraceTests {
    @Test("One line: UTC time to the millisecond, the category padded to 13, the text")
    func lineFormat() {
        let at = Date(timeIntervalSince1970: 1_763_332_863.123)   // 2025-11-16T22:41:03.123Z
        #expect(TraceLine.format(at: at, .oscIn, "/Syndicate/Deck/1/Playing 1")
            == "2025-11-16T22:41:03.123Z osc-in        /Syndicate/Deck/1/Playing 1")
        #expect(TraceLine.format(at: at, .subscriptions, "Cues: off")
            == "2025-11-16T22:41:03.123Z subscriptions Cues: off")
    }

    @Test("Each category's name, as os_log and the file use it")
    func categoryNames() {
        #expect(TraceCategory.allCases.map(\.rawValue) == [
            "midi-in", "midi-out", "osc-in", "osc-out", "jog-display", "display-feed", "coordinator", "capture", "quantize",
            "subscriptions", "error", "heartbeat",
        ])
    }

    @Test("The heartbeat (#595) keeps beating while the caller is stalled: it runs on no one's thread but its own")
    func heartbeatWhileStalled() {
        let beats = Beats()
        let fifth = DispatchSemaphore(value: 0)
        // A loaded runner (#657): the first beat is late, as when the timer's thread waits 0.25 s to be scheduled.
        let heartbeat = TraceHeartbeat(every: 0.02) { category, text in
            if text == "beat 1" { Thread.sleep(forTimeInterval: 0.25) }
            beats.add(category, text)
            if text == "beat 5" { fifth.signal() }
        }
        // The engine, stalled in a call that doesn't return: this thread is blocked until the fifth beat, so every beat
        // came from elsewhere. Not a fixed window (#657): a slow runner only makes the stall longer, up to 10 s.
        #expect(fifth.wait(timeout: .now() + 10) == .success)
        heartbeat.stop()
        let lines = beats.lines
        #expect(lines.count >= 5)
        #expect(lines.allSatisfy { $0.0 == .heartbeat })
        #expect(lines.first?.1 == "beat 1")
        let stopped = beats.lines.count
        Thread.sleep(forTimeInterval: 0.1)
        #expect(beats.lines.count == stopped, "no beat after stop")
    }

    @Test("Streaming OSC (Position, BarRamp, Meter, …) at most 5 a second per address; the next kept one counts what was skipped")
    func sampler() {
        var sampler = StreamSampler()
        let position = "/Syndicate/Deck/1/Position"
        var kept: [String] = []
        // 100 a second for half a second: one every 10 ms.
        for i in 0..<50 {
            if let note = sampler.admit(position, at: Double(i) * 0.01) { kept.append(note) }
        }
        #expect(kept == ["", " (+19 skipped)", " (+19 skipped)"])
        // Another deck's Position is its own stream.
        let otherDeck = sampler.admit("/Syndicate/Deck/2/Position", at: 0.49)
        #expect(otherDeck == "")
    }

    @Test("Everything else always passes, unsampled")
    func nonStreaming() {
        var sampler = StreamSampler()
        var playing: [String?] = []
        for _ in 0..<10 { playing.append(sampler.admit("/Syndicate/Deck/1/Playing", at: 1.0)) }
        #expect(playing == Array(repeating: "", count: 10))
        let first = sampler.admit("/Syndicate/Mixer/CH1/Meter", at: 1.0)
        let soon = sampler.admit("/Syndicate/Mixer/CH1/Meter", at: 1.05)
        #expect(first == "")
        #expect(soon == nil, "Meter is streaming on the mixer too")
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @Test("The rolling file appends lines; past the cap it moves deckbridge.log to .1 and .1 to .2, keeping 3 files")
    func rolling() throws {
        let directory = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = RollingLogFile(directory: directory, name: "deckbridge.log", cap: 20, keep: 3)
        for line in ["aaaaaaaaa", "bbbbbbbbb", "ccccccccc", "ddddddddd", "eeeeeeeee", "fffffffff", "ggggggggg"] {
            file.append(line)
        }
        let main = directory.appendingPathComponent("deckbridge.log")
        // Each line is 10 bytes with its newline; two fit under the 20-byte cap, the third rolls.
        #expect(Self.read(main) == "ggggggggg\n")
        #expect(Self.read(directory.appendingPathComponent("deckbridge.log.1")) == "eeeeeeeee\nfffffffff\n")
        #expect(Self.read(directory.appendingPathComponent("deckbridge.log.2")) == "ccccccccc\nddddddddd\n")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("deckbridge.log.3").path))
        #expect(file.url == main)
    }

    @Test("A missing folder is made; an existing file is appended to, not replaced")
    func appendsAcrossLaunches() throws {
        let directory = try Self.tempDirectory().appendingPathComponent("Logs/DeckBridge")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent()) }
        RollingLogFile(directory: directory, name: "deckbridge.log", cap: 1000, keep: 3).append("first launch")
        RollingLogFile(directory: directory, name: "deckbridge.log", cap: 1000, keep: 3).append("second launch")
        #expect(Self.read(directory.appendingPathComponent("deckbridge.log")) == "first launch\nsecond launch\n")
    }
}

/// The jog display's raw traffic in the trace (#395), for the WD stall work (#165, agent1): each SysEx out with its
/// command and length, each reply with its command, status and the time since the last send.
@Suite("Debug trace: the jog display's WD traffic")
struct TraceJogDisplayTests {
    final class Lines: @unchecked Sendable {
        var list: [String] = []
    }

    @Test("The drawn-display handshake's outcome is in the trace (#456): one line for no answer, one for an answer")
    func handshakeOutcome() {
        let silent = JogDisplayDriverTests.DriverRig()
        let lines = Lines()
        silent.driver.trace = { category, text in if category == .jogDisplay { lines.list.append(text) } }
        silent.driver.displayFirmware = .custom
        silent.driver.connect()
        silent.clock.now = 0.5
        silent.driver.tick()
        silent.driver.tick()
        #expect(lines.list.filter { $0 == "jog display: no drawn-display answer in 0.5 s, using images" }.count == 1)

        let drawing = JogDisplayDriverTests.DriverRig()
        lines.list.removeAll()
        drawing.driver.trace = { category, text in if category == .jogDisplay { lines.list.append(text) } }
        drawing.driver.displayFirmware = .custom
        drawing.driver.connect()
        drawing.driver.reply(DrawnDisplayHandshakeTests.answer)
        #expect(lines.list.contains("jog display: drawn display, protocol 1"))
    }

    /// #582: drawn messages are all command 0x20, and the needle and the meter are both 13 bytes, so the trace names the
    /// op: "WD out cmd=0x20 op=0A meter 13 bytes".
    @Test("A drawn message's trace line names its op, so a meter and a needle can be told apart")
    func drawnOpNamed() {
        #expect(JogDisplayDriver.describe(DrawnDisplay.Message.meter(level: 64, peak: 90).bytes) == "cmd=0x20 op=0A meter 13 bytes")
        #expect(JogDisplayDriver.describe(DrawnDisplay.Message.needle(4096).bytes) == "cmd=0x20 op=09 needle 13 bytes")
        #expect(JogDisplayDriver.describe(DrawnDisplay.Message.time(elapsedSeconds: 1, lengthSeconds: 2).bytes)
                == "cmd=0x20 op=06 time 15 bytes")
    }

    @Test("Hello on the controller port, the upload out on WD, each ack with its status and ms since the last send")
    func wdTraffic() {
        let rig = JogDisplayDriverTests.DriverRig()
        let lines = Lines()
        rig.driver.trace = { category, text in if category == .jogDisplay { lines.list.append(text) } }
        rig.clock.now = 100
        rig.driver.connect()
        #expect(lines.list == ["CTL out cmd=0x60 14 bytes", "CTL out F0 00 20 7F 01 F7"])
        lines.list.removeAll()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        let upload = JogDisplayDriverTests.upload(deck: 1, slot: 1)
        #expect(lines.list.count == upload.start.count + upload.body.count)
        // The play light off first (90 01 00), then the upload's frames: 0A, 0C, 0D …, 0E.
        #expect(lines.list.first == "WD out 90 01 00")
        #expect(lines.list.dropFirst().map { String($0.prefix(17)) }.first == "WD out cmd=0x0A 1")
        #expect(lines.list.dropFirst().allSatisfy { $0.hasPrefix("WD out cmd=0x") })
        lines.list.removeAll()
        rig.clock.now = 100.012
        rig.driver.reply(JogDisplayDriverTests.accepted)
        rig.clock.now = 100.020
        rig.driver.reply(JogDisplayDriverTests.refused)
        #expect(lines.list.prefix(2) == ["WD in cmd=0x0F status=0x00 +12 ms", "WD in cmd=0x0F status=0x06 +20 ms"])
    }

    @Test("The unit's identity reply carries its serial number in ASCII: the trace says it arrived, never the bytes")
    func identityRedacted() {
        let rig = JogDisplayDriverTests.DriverRig()
        let lines = Lines()
        rig.driver.trace = { category, text in if category == .jogDisplay { lines.list.append(text) } }
        rig.clock.now = 200
        rig.driver.connect()
        rig.driver.show(JogDisplayContent(deck: 1, color: [255, 0, 0]))
        lines.list.removeAll()
        rig.clock.now = 200.007
        // A universal identity reply (F0 7E <dev> 06 02 …) with a made-up serial "A12345" (41 31 32 33 34 35).
        rig.driver.reply([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x00, 0x02, 0x0B, 0x01, 0x00, 0x41, 0x31, 0x32, 0x33, 0x34, 0x35, 0xF7])
        #expect(lines.list == ["WD in identity reply (serial redacted) +7 ms"])
    }

    @Test("Short WD messages (the needle's pitch bend, the play light) as hex")
    func shortMessages() {
        let rig = JogDisplayDriverTests.DriverRig()
        let lines = Lines()
        rig.driver.trace = { category, text in if category == .jogDisplay { lines.list.append(text) } }
        rig.driver.connect()
        lines.list.removeAll()
        rig.driver.marker(4096)
        #expect(lines.list == ["WD out E0 00 20"])
    }
}

/// What a heartbeat sent, from its own thread.
private final class Beats: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [(TraceCategory, String)] = []
    func add(_ category: TraceCategory, _ text: String) { lock.withLock { kept.append((category, text)) } }
    var lines: [(TraceCategory, String)] { lock.withLock { kept } }
}
