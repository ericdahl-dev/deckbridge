import LC6000Update
import Testing
import UnitCheck

/// What a block B install writes (#751): only the sectors of 0x08080000-0x080FFFFF whose bytes change, B and then
/// erased flash to the end of any old B. Nothing below 0x08080000, ever.
@Suite("Block B: the sectors an install writes")
struct BlockBPlanTests {
    static func b() throws -> BlockB { try BlockBCheckTests.b() }
    static let empty = [UInt8](repeating: 0xFF, count: 0x8_0000)

    @Test("Onto erased flash: the one 128 KB sector B starts in, B then erased bytes")
    func fresh() throws {
        let b = try Self.b()
        let plan = WritePlan.blockB(b, backup: Self.empty)
        #expect(plan.sectors.map(\.address) == [0x0808_0000])
        #expect(plan.sectors[0].bytes == b.bytes + [UInt8](repeating: 0xFF, count: 0x2_0000 - b.bytes.count))
        #expect(plan.changedBytes == b.bytes.filter { $0 != 0xFF }.count)
    }

    @Test("Over a longer old B reaching sector 9: that sector is erased too, so nothing of the old B is left")
    func overALongerOne() throws {
        var backup = Self.empty
        for i in 0..<0x2_0010 { backup[i] = 0x33 }
        let plan = WritePlan.blockB(try Self.b(), backup: backup)
        #expect(plan.sectors.map(\.address) == [0x0808_0000, 0x080A_0000])
        #expect(plan.sectors[1].bytes == [UInt8](repeating: 0xFF, count: 0x2_0000))
    }

    @Test("The same B already there: nothing to write")
    func alreadyThere() throws {
        let b = try Self.b()
        var backup = Self.empty
        backup.replaceSubrange(0..<b.bytes.count, with: b.bytes)
        #expect(WritePlan.blockB(b, backup: backup).sectors.isEmpty)
    }

    @Test("Restore writes the backup's own bytes back to the same sectors")
    func restore() throws {
        var backup = Self.empty
        for i in 0..<0x2_0010 { backup[i] = 0x33 }
        let restore = WritePlan.blockB(try Self.b(), backup: backup).restore
        #expect(restore.sectors.map(\.address) == [0x0808_0000, 0x080A_0000])
        #expect(restore.sectors[0].bytes == Array(backup[0..<0x2_0000]))
        #expect(restore.sectors[1].bytes == Array(backup[0x2_0000..<0x4_0000]))
    }

    @Test("The confirm's words: block B, the sectors with their sizes, and nothing below 0x08080000")
    func text() throws {
        let plan = WritePlan.blockB(try Self.b(), backup: Self.empty)
        #expect(plan.text == """
            The display chip: 1 flash sector is erased and written with block B, 0x08080000-0x0809FFFF (128 KB). \
            \(plan.changedBytes) bytes differ from your backup. Nothing below 0x08080000, Denon's image and our hook, is touched.
            """)
    }
}
