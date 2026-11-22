// The debug trace (#395): Debug builds log everything an agent needs to diagnose the hardware to os_log and to a rolling
// file it can read directly. Release and TestFlight builds compile none of this. Not unit-tested: the line format, the
// sampler and the rolling file are tested in ControllerBridgeKit (TraceTests); this is the wiring.
#if DEBUG
import ControllerBridgeCore
import Foundation
import os

final class DebugTrace: @unchecked Sendable {
    static let shared = DebugTrace()

    /// The app container's Library/Logs/DeckBridge/deckbridge.log (sandboxed, so under the container).
    let fileURL: URL
    private let file: RollingLogFile
    /// The file's writer: its queue keeps the lines in order off the caller, and flush() holds a quit for them (#653).
    private let writer: TraceWriter
    private let loggers: [TraceCategory: Logger]
    /// The last status summary written, so only changes are logged.
    private var lastStatus = ""
    /// A line every 0.5 s from a timer that isn't the engine (#595): a silent stretch with beats in it is the engine
    /// stalled; one without is the whole process.
    private var heartbeat: TraceHeartbeat?

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DeckBridge", isDirectory: true)
        file = RollingLogFile(directory: logs, name: "deckbridge.log", cap: 20_000_000, keep: 3)
        fileURL = file.url
        writer = TraceWriter(file)
        loggers = Dictionary(uniqueKeysWithValues: TraceCategory.allCases.map {
            ($0, Logger(subsystem: "dev.ericdahl.ControllerBridge", category: $0.rawValue))
        })
        // Each launch starts with where the file is, so an agent reading os_log finds it too.
        let path = fileURL.path
        loggers[.coordinator]?.notice("Debug trace file: \(path, privacy: .public)")
        file.append(TraceLine.format(at: .now, .coordinator, "Debug trace started; file \(path)"))
        heartbeat = TraceHeartbeat(every: 0.5, sink: sink)
    }

    /// Where the Kit's trace goes: os_log at once, the file on a background queue.
    var sink: TraceSink {
        { [self] category, text in
            let now = Date.now
            if category == .error { loggers[category]?.error("\(text, privacy: .public)") } else {
                loggers[category]?.debug("\(text, privacy: .public)")
            }
            writer.append(TraceLine.format(at: now, category, text))
        }
    }

    /// Waits until every line so far is in the file: a quit calls it, so the trace's last line is the last thing done.
    func flush() { writer.flush() }

    /// A debug capture (#582) as its own file beside the trace, named with the time; its path goes to the trace.
    func writeCapture(_ text: String, named name: String) {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let url = fileURL.deletingLastPathComponent().appendingPathComponent("\(name)-\(stamp).csv")
        writer.async {
            try? Data(text.utf8).write(to: url)
            self.file.append(TraceLine.format(at: .now, .coordinator, "Meter capture written: \(url.path)"))
        }
    }

    /// The Coordinator's status, logged when it changes: controllers (deck, layer, profile, connection), feedback,
    /// missing subscriptions and another host.
    func status(_ status: CoordinatorStatus) {
        let summary = "controllers \(status.controllers) feedback \(status.feedback) missing subscriptions "
            + "\(status.missingSubscriptions) other host \(status.otherHost)"
        writer.async {
            guard summary != self.lastStatus else { return }
            self.lastStatus = summary
            self.file.append(TraceLine.format(at: .now, .coordinator, summary))
            if !status.missingSubscriptions.isEmpty {
                self.file.append(TraceLine.format(at: .now, .subscriptions, "missing: \(status.missingSubscriptions)"))
            }
        }
    }
}
#endif
