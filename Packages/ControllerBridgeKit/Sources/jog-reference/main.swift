// jog-reference <manifest.json> <out-dir> [file ...] (#571)
// Renders the drawn display's reference images from the one list, tools/lc6000-display-fw/test/ref/manifest.json:
// every entry, or only the named files, each as a binary PPM (P6, RGB) in <out-dir> (DrawnReference.ppm). The Kit's
// DisplayFirmwareReferenceTests checks the same entries against the renderer, so nothing is rendered any other way.
import ControllerBridgeRender
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { fail("Usage: jog-reference <manifest.json> <out-dir> [file ...]") }
let entries: [DrawnReference.Entry]
do { entries = try DrawnReference.manifest(at: URL(fileURLWithPath: arguments[0])) } catch { fail("Can't read \(arguments[0]): \(error)") }
let wanted = Set(arguments.dropFirst(2))
let unknown = wanted.subtracting(entries.map(\.file))
guard unknown.isEmpty else { fail("Not in the manifest: \(unknown.sorted().joined(separator: ", "))") }
for entry in entries where wanted.isEmpty || wanted.contains(entry.file) {
    do { _ = try DrawnReference.inputs(entry) } catch { fail("\(error)") }
    let url = URL(fileURLWithPath: arguments[1]).appendingPathComponent(entry.file)
    do { try DrawnReference.ppm(entry).write(to: url) } catch { fail("Can't write \(url.path): \(error)") }
}
