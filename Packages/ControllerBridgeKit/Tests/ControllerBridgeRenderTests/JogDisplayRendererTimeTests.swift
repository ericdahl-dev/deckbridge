import ControllerBridgeCore
@testable import ControllerBridgeRender
import Testing

/// Track time's remaining text (#460) in the 198 frame. The progress ring moved out to the band (#524):
/// JogDisplayProgressRingTests.
@Suite("Jog display renderer: track time")
struct JogDisplayRendererTimeTests {
    static let content = JogDisplayContent(deck: 2, color: [255, 0, 0], title: "Daybreak", artist: "Night Drive",
                                           key: "A#m", bpm: 128, playerType: "track")

    static func image(_ time: (elapsed: Int, length: Int)?) -> [UInt8] {
        JogDisplayRenderer.simulatorImage(content, litBeat: nil, marker: nil, time: time)
    }

    /// The pixels (x, y) where two images differ.
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> [(x: Int, y: Int)] {
        (0..<198 * 198).compactMap { i in a[i * 4..<i * 4 + 3] == b[i * 4..<i * 4 + 3] ? nil : (i % 198, i / 198) }
    }

    static func radius(_ p: (x: Int, y: Int)) -> Double {
        let dx = Double(p.x) + 0.5 - 99, dy = Double(p.y) + 0.5 - 99
        return (dx * dx + dy * dy).squareRoot()
    }

    @Test("No time, or an unknown length, draws nothing of it")
    func nothingWithoutLength() {
        let plain = JogDisplayRenderer.simulatorImage(Self.content, litBeat: nil, marker: nil)
        #expect(Self.image(nil) == plain)
        #expect(Self.image((elapsed: 42, length: 0)) == plain)
    }

    /// "-99:59" is the widest a track under 100 minutes shows.
    @Test("The remaining time draws below key/BPM, inside the text-safe circle, centered", arguments: [
        (elapsed: 0, length: 165), (elapsed: 600, length: 4365), (elapsed: 0, length: 5999),
    ])
    func remainingFits(elapsed: Int, length: Int) {
        let inside = Self.changed(Self.image(nil), Self.image((elapsed, length))).filter { Self.radius($0) < 90 }
        #expect(!inside.isEmpty)
        // Below key/BPM's ink (its last row is y 159), a gap between, and inside the text-safe circle (r 79).
        #expect(inside.allSatisfy { $0.y >= 162 })
        #expect(inside.allSatisfy { Self.radius($0) <= JogDisplayRenderer.safe })
        let xs = inside.map(\.x)
        #expect(abs((xs.min()! + xs.max()!) / 2 - 99) <= 2)
    }

    @Test("Different remaining times draw differently; past the end shows no less than -0:00")
    func remainingTracksTime() {
        #expect(Self.image((elapsed: 0, length: 165)) != Self.image((elapsed: 1, length: 165)))
        #expect(Self.image((elapsed: 200, length: 165)) == Self.image((elapsed: 165, length: 165)))
    }

    static func slot(_ image: [UInt8]) -> [[UInt8]] {
        (163...175).flatMap { y in (60...138).map { x in Self.at(image, x, y) } }
    }

    static func at(_ image: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { JogDisplayRendererTests.pixel(image, x: x, y: y) }

    @Test("The warning's red half: the remaining time and the ring's fill turn red (0xFF3B30); the track stays dark")
    func warningRed() {
        let image = JogDisplayRenderer.simulatorImage(Self.content, litBeat: nil, marker: nil,
                                                      time: (elapsed: 90, length: 120), look: .warningRed)
        #expect(Self.slot(image).contains { JogDisplayRendererTests.near($0, 0xFF3B30, by: 8) })
        #expect(!Self.slot(image).contains { JogDisplayRendererTests.near($0, 0xEDEDEA, by: 8) })
    }

    @Test("Without the warning the remaining time is white and the fill the deck color")
    func warningOff() {
        let image = Self.image((elapsed: 90, length: 120))
        #expect(Self.slot(image).contains { JogDisplayRendererTests.near($0, 0xEDEDEA, by: 8) })
        #expect(!Self.slot(image).contains { JogDisplayRendererTests.near($0, 0xFF3B30, by: 8) })
    }

    @Test("The blink's white half: text and ring fill white (0xEDEDEA) on any deck, red or blue")
    func warningWhiteHalf() {
        let blue = JogDisplayContent(deck: 4, color: [0, 128, 255], title: "Daybreak", playerType: "track")
        for content in [Self.content, blue] {
            let image = JogDisplayRenderer.simulatorImage(content, litBeat: nil, marker: nil,
                                                          time: (elapsed: 90, length: 120), look: .warningWhite)
            #expect(Self.slot(image).contains { JogDisplayRendererTests.near($0, 0xEDEDEA, by: 8) })
            #expect(!Self.slot(image).contains { JogDisplayRendererTests.near($0, 0xFF3B30, by: 8) })
        }
    }

}
