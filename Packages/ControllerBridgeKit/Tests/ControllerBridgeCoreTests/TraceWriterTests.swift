import ControllerBridgeCore
import Foundation
import Testing

/// #653: the trace's last line must be trustworthy after a quit, so the writer flushes what it has queued.
@Suite("Trace writer")
struct TraceWriterTests {
    @Test("After flush, every line appended so far is in the file, in order")
    func flushWritesEverything() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trace-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = RollingLogFile(directory: directory, name: "t.log")
        let writer = TraceWriter(file)
        for n in 0..<20_000 { writer.append("line \(n)") }
        writer.flush()
        let lines = try String(contentsOf: file.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 20_000)
        #expect(lines.last == "line 19999")
    }
}
