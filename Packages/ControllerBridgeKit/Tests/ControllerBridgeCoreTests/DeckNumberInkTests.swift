@testable import ControllerBridgeCore
import Testing

/// The deck number's ink on its deck color (agent3's note on #542): black, unless white reads better. The WCAG rule:
/// white when its contrast with the color beats black's, i.e. the color's relative luminance is under about 0.179.
@Suite("Deck number: black or white on the deck color")
struct DeckNumberInkTests {
    static let white: [[Int]] = [[0, 0, 255], [0, 0, 128], [0, 128, 0], [64, 64, 64], [128, 0, 128], [0, 0, 0]]
    static let black: [[Int]] = [[255, 0, 0], [255, 255, 0], [0, 255, 255], [0, 128, 255], [128, 128, 128], [255, 255, 255]]

    @Test("Dark deck colors get a white number", arguments: white)
    func darkIsWhite(color: [Int]) {
        #expect(DeckNumberInk.white(on: color))
    }

    @Test("Light deck colors keep the black number", arguments: black)
    func lightIsBlack(color: [Int]) {
        #expect(!DeckNumberInk.white(on: color))
    }
}
