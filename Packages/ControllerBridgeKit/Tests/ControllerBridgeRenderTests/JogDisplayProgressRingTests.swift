import ControllerBridgeCore
@testable import ControllerBridgeRender
import Testing

/// The progress ring in the band outside the frame (#524), the user's pick: r 103–107 from the frame's center, 4 px,
/// a track of 0x4A4A4A, filled clockwise from 12 in the deck color (red, or white in the blink's other half, in the
/// warning). Nothing at r 96–98 any more; the needle (to r 98.5) no longer crosses it. Drawn mode only: drawnImage.
@Suite("Jog display renderer: the progress ring in the band")
struct JogDisplayProgressRingTests {
    static let content = JogDisplayRendererTimeTests.content
    static let center = 108.0

    static func image(_ time: DrawnLive.Time?, look: JogTrackTime.Look = .normal, needle: Int? = nil) -> [UInt8] {
        JogDisplayRenderer.drawnImage(content, live: DrawnLive(needle: needle, time: time, look: look))
    }

    static func at(_ image: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { JogDisplayDrawnImageTests.pixel(image, x: x, y: y) }

    static func radius(_ i: Int) -> Double {
        let dx = Double(i % 216) + 0.5 - center, dy = Double(i / 216) + 0.5 - center
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Where two canvases differ, as indices.
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> [Int] {
        (0..<216 * 216).filter { a[$0 * 4..<$0 * 4 + 3] != b[$0 * 4..<$0 * 4 + 3] }
    }

    /// Mid-band points (r ≈ 105): (126, 4) at 10°, (212, 107) at 90°, (107, 212) at 180°, (3, 107) at 270°.
    static let points = [(126, 4), (212, 107), (107, 212), (3, 107)]

    @Test("Halfway: lit in the deck color to 6 o'clock, the track after")
    func halfway() {
        let image = Self.image(.init(elapsed: 60, length: 120))
        #expect(JogDisplayRendererTests.near(Self.at(image, 126, 4), 0xFF0000))
        #expect(JogDisplayRendererTests.near(Self.at(image, 212, 107), 0xFF0000))
        #expect(JogDisplayRendererTests.near(Self.at(image, 3, 107), 0x4A4A4A))
    }

    @Test("At the start the whole ring is the track; at the end all lit")
    func ends() {
        let start = Self.image(.init(elapsed: 0, length: 120)), end = Self.image(.init(elapsed: 120, length: 120))
        for (x, y) in Self.points {
            #expect(JogDisplayRendererTests.near(Self.at(start, x, y), 0x4A4A4A))
            #expect(JogDisplayRendererTests.near(Self.at(end, x, y), 0xFF0000))
        }
    }

    @Test("The ring is only in its band, r 103–107: nothing at r 96–98, nothing past 107")
    func band() {
        let ring = Self.changed(Self.image(nil), Self.image(.init(elapsed: 60, length: 120))).filter { Self.radius($0) >= 90 }
        #expect(!ring.isEmpty)
        #expect(ring.allSatisfy { Self.radius($0) > 102 && Self.radius($0) < 108 })
    }

    @Test("Unknown length: no ring")
    func unknown() {
        #expect(Self.image(.init(elapsed: 42, length: 0)) == Self.image(nil))
    }

    @Test("The warning: red fill, or white in the blink's other half; the track stays")
    func warning() {
        let red = Self.image(.init(elapsed: 100, length: 120), look: .warningRed)
        #expect(JogDisplayRendererTests.near(Self.at(red, 212, 107), 0xFF3B30, by: 8))
        #expect(JogDisplayRendererTests.near(Self.at(red, 55, 16), 0x4A4A4A))   // 330°, past the fill's 300°
        let white = Self.image(.init(elapsed: 100, length: 120), look: .warningWhite)
        #expect(JogDisplayRendererTests.near(Self.at(white, 212, 107), 0xEDEDEA, by: 8))
    }

    @Test("The needle at 3 o'clock no longer reaches the ring")
    func needleClear() {
        let image = Self.image(.init(elapsed: 60, length: 120), needle: 4096)
        #expect(JogDisplayRendererTests.near(Self.at(image, 212, 107), 0xFF0000))
    }
}
