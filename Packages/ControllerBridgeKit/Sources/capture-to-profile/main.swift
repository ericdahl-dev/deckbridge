// capture-to-profile <capture.json> [--docs facts.json] [--out dir] (#189)
// capture-to-profile --device <name> --docs facts.json [--out dir] (#280: from the docs alone, before any capture)
// Writes <id>.json (the draft profile), <id>.fixture.json (the replay fixture, with a capture only) and <id>.report.md
// (problems, disagreements and TODOs) into the out directory (default: the current one). Exits 1 on a bad input.
import ControllerBridgeCapture
import ControllerBridgeDraft
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value.") }
    defer { arguments.removeSubrange(index...index + 1) }
    return arguments[index + 1]
}
let docsPath = option("--docs")
let device = option("--device")
let out = URL(fileURLWithPath: option("--out") ?? FileManager.default.currentDirectoryPath)
let usage = "Usage: capture-to-profile <capture.json> [--docs facts.json] [--out dir]\n"
    + "       capture-to-profile --device <name> --docs facts.json [--out dir]"

let docs: DocsFacts
do { docs = try docsPath.map { try DocsFacts(json: Data(contentsOf: URL(fileURLWithPath: $0))) } ?? DocsFacts() } catch { fail("Can't read the docs facts: \(error)") }

@MainActor func write(_ draft: ProfileDraft, fixture: DraftJSON?) {
    guard case .string(let id)? = draft.file["id"] else { fail("The draft has no id.") }
    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try (draft.file.text() + "\n").write(to: out.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
        if let fixture {
            try (fixture.text() + "\n").write(to: out.appendingPathComponent("\(id).fixture.json"), atomically: true, encoding: .utf8)
        }
        try DraftReport.text(draft).write(to: out.appendingPathComponent("\(id).report.md"), atomically: true, encoding: .utf8)
    } catch { fail("Can't write the draft: \(error)") }
    print("Wrote \(id).json\(fixture == nil ? "" : ", \(id).fixture.json") and \(id).report.md to \(out.path): \(draft.todos.count) TODOs, "
          + "\(draft.conflicts.count) disagreements, \(draft.problems.count) import problems.")
}

if let device {
    guard arguments.isEmpty, docsPath != nil else { fail(usage) }
    write(ProfileDraft.make(device: device, docs: docs), fixture: nil)
    exit(0)
}
guard arguments.count == 1 else { fail(usage) }

let capture: CaptureFile
do { capture = try CaptureFile.decode(Data(contentsOf: URL(fileURLWithPath: arguments[0]))) } catch { fail("Can't read the capture: \(error)") }

let draft = ProfileDraft.make(capture: capture, docs: docs)
guard case .string(let id)? = draft.file["id"] else { fail("The draft has no id.") }
write(draft, fixture: ReplayFixture.make(capture: capture, profile: id))
