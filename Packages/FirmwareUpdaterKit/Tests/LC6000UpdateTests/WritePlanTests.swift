import FirmwareCatalog
import LC6000Update
import Testing
import UnitCheck

/// What an update writes (#693): only the flash sectors whose bytes change, each erased and written whole with the
/// patched image's bytes. Every other sector is untouched. The plan says exactly that, for the confirm and the PR.
@Suite("LC6000 update: the sectors a patch writes")
struct WritePlanTests {
    typealias V = PatchVectorTests

    @Test("Display chip, the slot-16 patch: the 16 KB sector with its byte, and the last 128 KB one with the CRC")
    func display() throws {
        let v = try PatchStateTests.vector("wd 00.50 slot-16")
        let stock = V.element(v, size: 0x7_8000)
        let patched = try PatchedImage.apply(try V.edits(v), chip: .wd, to: stock)
        let plan = WritePlan(chip: .display, backup: stock, patched: patched)
        #expect(plan.sectors.map(\.address) == [0x0800_8000, 0x0806_0000])
        #expect(plan.sectors.map(\.bytes.count) == [0x4000, 0x2_0000])
        #expect(plan.sectors[0].bytes == Array(patched[0..<0x4000]))
        #expect(plan.sectors[1].bytes == Array(patched[0x5_8000..<0x7_8000]))
        #expect(plan.changedBytes == 1 + 4)  // the compare's immediate, and the trailer CRC
        #expect(plan.text == """
            The display chip: 2 flash sectors are erased and written with the patched image, 0x08008000-0x0800BFFF \
            (16 KB) and 0x08060000-0x0807FFFF (128 KB). 5 bytes differ from your backup. Every other sector is untouched.
            """)
    }

    @Test("Top panel chip, the no-deck-select patch: only the 64 KB sector holding it")
    func topPanel() throws {
        let v = try PatchStateTests.vector("tp 00.31")
        let stock = V.element(v) + [UInt8](repeating: 0xFF, count: 0x3_8000 - 0xE000)
        let patched = try PatchedImage.apply(try V.edits(v), chip: .tp, to: stock)
        let plan = WritePlan(chip: .topPanel, backup: stock, patched: patched)
        #expect(plan.sectors.map(\.address) == [0x0801_0000])
        #expect(plan.sectors[0].bytes == Array(patched[0x8000..<0x1_8000]))
        #expect(plan.text == """
            The top panel chip: 1 flash sector is erased and written with the patched image, 0x08010000-0x0801FFFF \
            (64 KB). 1 byte differs from your backup. Every other sector is untouched.
            """)
    }

    @Test("Restore: the same sectors, with the backup's bytes")
    func restore() throws {
        let v = try PatchStateTests.vector("wd 00.50 slot-16")
        let stock = V.element(v, size: 0x7_8000)
        let patched = try PatchedImage.apply(try V.edits(v), chip: .wd, to: stock)
        let plan = WritePlan(chip: .display, backup: stock, patched: patched)
        let restore = plan.restore
        #expect(restore.sectors.map(\.address) == plan.sectors.map(\.address))
        #expect(restore.sectors[0].bytes == Array(stock[0..<0x4000]))
        #expect(restore.sectors[1].bytes == Array(stock[0x5_8000..<0x7_8000]))
    }

    @Test("Nothing differs: nothing to write")
    func nothing() throws {
        let v = try PatchStateTests.vector("wd 00.50 slot-16")
        let stock = V.element(v, size: 0x7_8000)
        #expect(WritePlan(chip: .display, backup: stock, patched: stock).sectors.isEmpty)
    }
}
