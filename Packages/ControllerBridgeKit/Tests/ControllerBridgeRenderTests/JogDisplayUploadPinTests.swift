import ControllerBridgeCore
@testable import ControllerBridgeRender
import Testing

/// Image mode's uploads keep design B's foot (#524): the drawn layout's changes (key/BPM 18 px, the time line) are
/// drawn mode's only. Checked by where the foot's ink lands, not by bytes: CI's text rendering differs a little from
/// a Mac's, so an exact pin can't hold.
@Suite("Jog display renderer: uploads unchanged")
struct JogDisplayUploadPinTests {
    static let content = JogDisplayContent(deck: 2, color: [255, 0, 0], title: "Daybreak", artist: "Night Drive",
                                           key: "12A", bpm: 174, playerType: "track")

    /// Rows below the rule and inside r 84 with any ink.
    static func footRows(_ image: [UInt8]) -> Set<Int> {
        Set((0..<198 * 198).compactMap { i -> Int? in
            let x = i % 198, y = i / 198
            guard y > 131, JogDisplayRendererTimeTests.radius((x, y)) < 84 else { return nil }
            return image[i * 4..<i * 4 + 3].elementsEqual([0x0B, 0x0B, 0x0B]) ? nil : y
        })
    }

    @Test("The upload's foot is key/BPM at 22 px from y 136, its ink rows 142-159, and no time line under it")
    func designBFoot() {
        let rows = Self.footRows(JogDisplayRenderer.uploadImage(Self.content))
        #expect((17...19).contains(rows.count))
        #expect((141...143).contains(rows.min()!))
        #expect(rows.max()! <= 160)
    }
}
