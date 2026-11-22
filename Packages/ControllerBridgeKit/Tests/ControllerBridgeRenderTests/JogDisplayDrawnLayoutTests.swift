import ControllerBridgeCore
@testable import ControllerBridgeRender
import Testing

/// Drawn mode's own layout (#524), the user's pick: under the rule, key/BPM at 18 px (images keep 22) and the remaining
/// time at 21 px (images have none). Both whole inside the text-safe circle (r 79) with "12A 174.0" and "-99:59", the
/// widest realistic, and a gap between them.
@Suite("Jog display renderer: the drawn layout")
struct JogDisplayDrawnLayoutTests {
    static let content = JogDisplayContent(deck: 2, color: [255, 0, 0], title: "Daybreak", artist: "Night Drive",
                                           key: "12A", bpm: 174, playerType: "track")
    typealias Point = (x: Int, y: Int)

    /// Ink below the rule and inside r 84, in frame coordinates: everything there that isn't the ground.
    static func ink(_ image: [UInt8]) -> [Point] {
        (0..<216 * 216).compactMap { i in
            let x = i % 216 - 9, y = i / 216 - 9
            guard y > 131, JogDisplayRendererTimeTests.radius((x, y)) < 84 else { return nil }
            return image[i * 4..<i * 4 + 3].elementsEqual([0x0B, 0x0B, 0x0B]) ? nil : (x, y)
        }
    }

    static let keyInk = ink(JogDisplayRenderer.drawnImage(content, live: DrawnLive()))
    static let allInk = ink(JogDisplayRenderer.drawnImage(content, live: DrawnLive(time: .init(elapsed: 0, length: 5999))))
    static var timeInk: [Point] { allInk.filter { $0.y > keyInk.map(\.y).max()! } }

    /// Ink rows, edges anti-aliased: 18 px covers 15 rows; image mode's 22 px covers 18.
    @Test("Key/BPM is 18 px: its ink 15 rows, not 22 px's 18")
    func keySize() {
        let rows = Set(Self.keyInk.map(\.y))
        #expect((14...16).contains(rows.count))
    }

    /// 21 px covers 17 rows; image mode's 14 px covers 13.
    @Test("The time is 21 px: its ink 17 rows, not 14 px's 13")
    func timeSize() {
        let rows = Set(Self.timeInk.map(\.y))
        #expect((16...18).contains(rows.count))
    }

    @Test("Both lines whole inside the text-safe circle, the time below key/BPM with a gap")
    func fits() {
        #expect(Self.allInk.allSatisfy { JogDisplayRendererTimeTests.radius($0) <= JogDisplayRenderer.safe })
        #expect(Self.timeInk.map(\.y).min()! >= Self.keyInk.map(\.y).max()! + 4)
    }
}
