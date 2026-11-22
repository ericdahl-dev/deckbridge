import ControllerBridgeCore
@testable import ControllerBridgeRender
import Testing

/// The drawn display as the panel shows it (#524, #465): a 216×216 canvas with the 198 frame centered (+9), so the band
/// outside the frame (the progress ring's place) shows too. The panel around the frame is black. Image mode keeps
/// simulatorImage and uploadImage.
@Suite("Jog display renderer: the drawn image")
struct JogDisplayDrawnImageTests {
    static let content = JogDisplayContent(deck: 2, color: [255, 0, 0], title: "Daybreak", artist: "Night Drive",
                                           key: "A#m", bpm: 128, playerType: "track")

    static func pixel(_ rgba: [UInt8], x: Int, y: Int) -> [UInt8] {
        Array(rgba[(y * 216 + x) * 4..<(y * 216 + x) * 4 + 4])
    }

    @Test("A 216×216 RGBA image, black around the frame")
    func canvas() {
        let image = JogDisplayRenderer.drawnImage(Self.content, live: DrawnLive())
        #expect(image.count == 216 * 216 * 4)
        for (x, y) in [(0, 0), (215, 0), (0, 215), (215, 215), (4, 108)] {
            #expect(Self.pixel(image, x: x, y: y) == [0, 0, 0, 255])
        }
    }

    @Test("The deck's chip sits where the frame's does, 9 px in: the frame is centered")
    func centered() {
        let image = JogDisplayRenderer.drawnImage(Self.content, live: DrawnLive())
        let frame = JogDisplayRenderer.uploadImage(Self.content)
        // The chip's center in the frame is near (86, 37) for a deck with a badge; take the frame's own pixel there.
        let inFrame = JogDisplayRendererTests.pixel(frame, x: 86, y: 37)
        #expect(Self.pixel(image, x: 86 + 9, y: 37 + 9) == inFrame)
        // The frame's square starts exactly 9 px in: its ground at (9, 9) and (206, 206), the panel's black just outside.
        for (x, y) in [(9, 9), (206, 206)] { #expect(Self.pixel(image, x: x, y: y) == [0x0B, 0x0B, 0x0B, 255]) }
        for (x, y) in [(8, 8), (207, 207)] { #expect(Self.pixel(image, x: x, y: y) == [0, 0, 0, 255]) }
    }

    @Test("The live parts draw: a lit beat and the needle change the image")
    func live() {
        let plain = JogDisplayRenderer.drawnImage(Self.content, live: DrawnLive())
        #expect(JogDisplayRenderer.drawnImage(Self.content, live: DrawnLive(beat: 2)) != plain)
        #expect(JogDisplayRenderer.drawnImage(Self.content, live: DrawnLive(needle: 4096)) != plain)
        #expect(JogDisplayRenderer.drawnImage(Self.content, live: DrawnLive(meter: .init(level: 64, peak: 90))) != plain)
        #expect(JogDisplayRenderer.drawnImage(Self.content, live: DrawnLive(time: .init(elapsed: 10, length: 100))) != plain)
    }
}
