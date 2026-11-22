import Foundation

/// The debug trace (#395): what a Debug build writes to os_log and to a rolling file, so an agent can read what the
/// controller, Syndicate and the jog display did without asking the user for a paste. Release builds never set it.
public enum TraceCategory: String, CaseIterable, Sendable {
    case midiIn = "midi-in"
    case midiOut = "midi-out"
    case oscIn = "osc-in"
    case oscOut = "osc-out"
    case jogDisplay = "jog-display"
    /// The display feed to the deck panel (#636): the setting, its destination, each full snapshot, the queue's drops.
    case displayFeed = "display-feed"
    case coordinator
    case capture
    case quantize
    case subscriptions
    case error
    case heartbeat
}

/// A trace line every `interval` from a timer of its own (#595), never the engine's: when the trace goes silent, beats
/// that go on say the engine stalled; beats that stop too say the whole process did.
public final class TraceHeartbeat: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.ericdahl.ControllerBridge.heartbeat")
    private let timer: DispatchSourceTimer
    private var count = 0   // touched only on `queue`

    public init(every interval: Double, sink: @escaping TraceSink) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [unowned self] in
            count += 1
            sink(.heartbeat, "beat \(count)")
        }
        timer.resume()
    }

    /// No beat after this returns: a beat already running is waited out.
    public func stop() {
        timer.cancel()
        queue.sync {}
    }

    deinit { timer.cancel() }
}

/// Where trace lines go: `(category, text)`. Nil (Release, tests that don't look) costs nothing.
public typealias TraceSink = @Sendable (TraceCategory, String) -> Void

public enum TraceLine {
    /// "2025-11-16T22:41:03.123Z osc-in        /Syndicate/Deck/1/Playing 1": UTC to the millisecond, the category
    /// padded to the longest (13), the text. One line, so `grep` and `tail` work on the file.
    public static func format(at date: Date, _ category: TraceCategory, _ text: String) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                        from: Date(timeIntervalSince1970: Double(millis / 1000)))
        let stamp = String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0, Int(millis % 1000))
        let name = category.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
        return "\(stamp) \(name) \(text.replacingOccurrences(of: "\n", with: " "))"
    }
}

/// Keeps the trace readable (#395): Syndicate streams some feedback (Position ~100/s per deck, BarRamp ~200/s, Meter
/// ~100/s per channel, #209), so each such address is kept at most `perSecond` times a second, and the next line kept
/// says how many were skipped. Every other message is kept.
public struct StreamSampler: Sendable {
    /// The streaming feedback, by the address's last part, as Diagnostics' streaming filter (#218).
    public static let streamingNames: Set<String> = ["position", "barramp", "meter", "clock", "currentstep", "sampleprogress",
                                                     "progress", "time"]
    public let perSecond: Double
    private var last: [String: Double] = [:]
    private var skipped: [String: Int] = [:]

    public init(perSecond: Double = 5) {
        self.perSecond = perSecond
    }

    /// Nil to skip this message; otherwise what to append to its line: "" or " (+N skipped)".
    public mutating func admit(_ address: String, at now: Double) -> String? {
        let name = address.split(separator: "/").last.map { $0.lowercased() } ?? ""
        guard Self.streamingNames.contains(name) else { return "" }
        if let previous = last[address], now - previous < 1 / perSecond - 1e-9 {
            skipped[address, default: 0] += 1
            return nil
        }
        last[address] = now
        let count = skipped.removeValue(forKey: address) ?? 0
        return count > 0 ? " (+\(count) skipped)" : ""
    }
}

/// The trace as a plain-text file an agent can read directly (#395): lines appended to `name` in `directory`; when a
/// line would take it past `cap` bytes, `name` becomes `name.1`, `.1` becomes `.2`, and so on, keeping `keep` files.
/// Thread-safe; the handle stays open between lines.
public final class RollingLogFile: @unchecked Sendable {
    public let url: URL
    private let directory: URL
    private let name: String
    private let cap: Int
    private let keep: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0

    public init(directory: URL, name: String = "deckbridge.log", cap: Int = 20_000_000, keep: Int = 3) {
        self.directory = directory
        self.name = name
        self.cap = cap
        self.keep = max(1, keep)
        url = directory.appendingPathComponent(name)
    }

    deinit { try? handle?.close() }

    public func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        if handle == nil { open() }
        if size > 0, size + data.count > cap { roll() }
        guard let handle else { return }
        handle.write(data)
        size += data.count
    }

    private func open() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func roll() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        func numbered(_ n: Int) -> URL { n == 0 ? url : directory.appendingPathComponent("\(name).\(n)") }
        try? manager.removeItem(at: numbered(keep - 1))
        for n in stride(from: keep - 2, through: 0, by: -1) where manager.fileExists(atPath: numbered(n).path) {
            try? manager.moveItem(at: numbered(n), to: numbered(n + 1))
        }
        open()
    }
}

/// The trace file's writer (#395, #653): lines go to the file on its own queue, so the caller never waits on the disk;
/// `flush()` waits until every line so far is in the file, so a quit leaves the trace's last line trustworthy.
public final class TraceWriter: @unchecked Sendable {
    private let file: RollingLogFile
    private let queue = DispatchQueue(label: "dev.ericdahl.ControllerBridge.trace")

    public init(_ file: RollingLogFile) { self.file = file }

    public func append(_ line: String) {
        queue.async { self.file.append(line) }
    }

    /// Runs `work` on the writer's queue, in order with the lines.
    public func async(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    public func flush() { queue.sync {} }
}

/// A LogSink that also writes each line to the trace, as a coordinator line (#395): connects, ports, problems.
struct TracingLog: LogSink {
    let base: any LogSink
    let trace: TraceSink?
    func log(_ line: String) {
        base.log(line)
        trace?(.coordinator, line)
    }
}

/// An LED output that also traces what it sends, with its port (#395).
struct TracingOutput: MIDIOutput {
    let inner: any MIDIOutput
    let name: String
    let trace: TraceSink
    /// A color-message LED's name in the profile ("ring", "pad3"), for its trace line (#530).
    var ledName: @Sendable (UInt8) -> String = { "note \($0)" }
    func send(_ event: MIDIEvent) throws {
        try inner.send(event)
        trace(.midiOut, "\(name) ch\(Int(event.channel) + 1) \(event.midoText)")
    }
    func send(color: LEDColorMessage) throws {
        try inner.send(color: color)
        trace(.midiOut, "\(name) color \(ledName(color.note)) r=\(color.red) g=\(color.green) b=\(color.blue)")
    }
    func close() { inner.close() }
}
