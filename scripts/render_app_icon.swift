// Renders a macOS AppIcon.appiconset (16-512 at @1x and @2x, plus Contents.json) from one square SVG (#733).
// Run: swift scripts/render_app_icon.swift design/icon/updater-download.svg Apps/FirmwareUpdater/Assets.xcassets/AppIcon.appiconset
// Check the result with scripts/check_app_icon.py --iconset.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: render_app_icon.swift icon.svg Out/AppIcon.appiconset\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let json = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]],
                                      options: [.prettyPrinted, .sortedKeys])
try (json + "\n".data(using: .utf8)!).write(to: out.appendingPathComponent("Contents.json"))
