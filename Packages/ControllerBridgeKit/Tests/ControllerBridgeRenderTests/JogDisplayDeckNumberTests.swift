import ControllerBridgeCore
@testable import ControllerBridgeRender
import Testing

/// The deck number on its color (DeckNumberInk): white on a dark deck, black on a light one, in the header's chip
/// (uploads and drawn) and in the stale logo's hub (drawn).
@Suite("Jog display renderer: the deck number's ink")
struct JogDisplayDeckNumberTests {
    static let dark = [0, 0, 128], light = [255, 0, 0]

    /// Pixels within `radius` of (x, y) that are near white (the text's 0xEDEDEA).
    static func whiteInk(_ image: [UInt8], x cx: Int, y cy: Int, radius: Int) -> Int {
        var count = 0
        for y in (cy - radius)...(cy + radius) {
            for x in (cx - radius)...(cx + radius) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius {
                if JogDisplayRendererTests.near(JogDisplayRendererTests.pixel(image, x: x, y: y), 0xEDEDEA, by: 24) { count += 1 }
            }
        }
        return count
    }

    @Test("The chip's number: white on a dark deck, none white on a light one")
    func chip() {
        // An empty deck has no badge: the chip is alone, centered on (99, 37).
        let dark = JogDisplayRenderer.uploadImage(JogDisplayContent(deck: 2, color: Self.dark))
        let light = JogDisplayRenderer.uploadImage(JogDisplayContent(deck: 2, color: Self.light))
        #expect(Self.whiteInk(dark, x: 99, y: 37, radius: 8) > 10)
        #expect(Self.whiteInk(light, x: 99, y: 37, radius: 8) == 0)
    }

    @Test("The stale hub's number: white on a dark deck, none white on a light one")
    func hub() {
        let dark = JogDisplayRenderer.render(JogDisplayContent(deck: 2, color: Self.dark, stale: true))
        let light = JogDisplayRenderer.render(JogDisplayContent(deck: 2, color: Self.light, stale: true))
        #expect(Self.whiteInk(dark, x: 99, y: 99, radius: 8) > 10)
        #expect(Self.whiteInk(light, x: 99, y: 99, radius: 8) == 0)
    }
}
