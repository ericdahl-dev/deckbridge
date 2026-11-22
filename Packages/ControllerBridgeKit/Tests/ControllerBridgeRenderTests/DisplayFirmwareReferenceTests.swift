import ControllerBridgeCore
@testable import ControllerBridgeRender
import Foundation
import Testing

/// The drawn display firmware's reference images (tools/lc6000-display-fw/test/ref, #457, #464) are this renderer's
/// output, and the C is checked against them. This checks them against the renderer as it is now, so a design change
/// here (the icon, design B) that isn't carried to the references, and so to the unit, fails.
@Suite("Display firmware references")
struct DisplayFirmwareReferenceTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // the package
        .deletingLastPathComponent().deletingLastPathComponent()                                 // the repo
        .appendingPathComponent("tools/lc6000-display-fw/test/ref")

    /// Every reference, from the one list make_refs.sh renders (#571): test/ref/manifest.json.
    static let manifest: [DrawnReference.Entry] = {
        (try? DrawnReference.manifest(at: directory.appendingPathComponent("manifest.json"))) ?? []
    }()

    /// A binary PPM's RGB bytes, or nil if it isn't a `size`×`size` one.
    static func rgb(_ file: String, size: Int = 198) -> [UInt8]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        let header = Data("P6\n\(size) \(size)\n255\n".utf8)
        guard data.starts(with: header), data.count == header.count + size * size * 3 else { return nil }
        return Array(data.dropFirst(header.count))
    }

    /// Slack for another Mac's rasterizer: CI's macOS draws text edges up to about 40 levels off this renderer's on
    /// a developer's Mac, and nothing else. So most pixels must be within a few levels, a bounded number of text edge
    /// pixels may be further off, and none by more than `cap`. A design change (a color, a size, a shape) moves far
    /// more pixels than the budget. Measured on CI (macos-26): worst 41, at most 51 pixels over 3; locally all exact.
    static let close = 3, budget = 150, cap = 64

    /// The manifest is every reference in the folder and nothing else: a reference can't be left out of the check.
    @Test("The manifest lists every reference image, each once")
    func manifestListsEveryReference() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path).filter { $0.hasSuffix(".ppm") }
        #expect(Self.manifest.count == 47)
        #expect(Set(Self.manifest.map(\.file)) == Set(files))
        #expect(Set(Self.manifest.map(\.file)).count == Self.manifest.count)
    }

    @Test("Each reference is what the renderer draws now", arguments: manifest.map(\.file))
    func referenceIsCurrent(file: String) throws {
        let entry = try #require(Self.manifest.first { $0.file == file })
        try compare(file, with: DrawnReference.render(entry), size: entry.size)
    }

    /// The phase rule's references (#462), from the manifest: deck 4, empty, blue.
    @Test("Each phase reference is what the renderer draws now", arguments: [0, -164, 164, -1638, 8191])
    func phaseReferenceIsCurrent(phase: Int) throws {
        let file = "deck4-blue-empty-phase\(phase).ppm"
        let entry = try #require(Self.manifest.first { $0.file == file })
        #expect(entry.phase == phase)
        let rendered = DrawnReference.render(entry)
        try compare(file, with: rendered, size: entry.size)
        // The rule's rows hold no text, so no rasterizer slack: every pixel there within `close`.
        let reference = try #require(Self.rgb(file))
        var off = 0
        for pixel in 124 * 198..<132 * 198 {
            for channel in 0..<3 {
                let difference = abs(Int(rendered[pixel * 3 + channel]) - Int(reference[pixel * 3 + channel]))
                if difference > Self.close {
                    off += 1
                    break
                }
            }
        }
        #expect(off == 0, "\(file): \(off) pixels of the rule's rows off")
    }

    /// The reference against the renderer's RGB (DrawnReference.render), within the tolerance above.
    private func compare(_ file: String, with rendered: [UInt8], size: Int) throws {
        let reference = try #require(Self.rgb(file, size: size), "missing or malformed \(file)")
        #expect(rendered.count == reference.count)
        var worst = 0, loose = 0
        for pixel in 0..<min(rendered.count, reference.count) / 3 {
            var difference = 0
            for channel in 0..<3 {
                difference = max(difference, abs(Int(rendered[pixel * 3 + channel]) - Int(reference[pixel * 3 + channel])))
            }
            worst = max(worst, difference)
            if difference > Self.close { loose += 1 }
        }
        print("\(file): worst \(worst), \(loose) pixels over \(Self.close)")
        #expect(worst <= Self.cap && loose <= Self.budget, "\(file): worst \(worst), \(loose) pixels over \(Self.close)")
    }
}
