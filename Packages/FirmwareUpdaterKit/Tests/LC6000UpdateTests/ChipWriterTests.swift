import FirmwareCatalog
import LC6000Update
import Testing
import UnitCheck

/// Writing an LC6000 chip (#693), on a fake chip only: nothing goes out before the owner's confirm of this very plan;
/// then the plan's sectors are erased and written, read back and compared. Restore writes the backup's same sectors.
@Suite("LC6000 update: writing, reading back, restoring")
struct ChipWriterTests {
    typealias V = PatchVectorTests

    /// The display chip with stock made-up 00.50 in its app area, and the slot-16 plan for it.
    static func display() throws -> (FlashChip, WritePlan, stock: [UInt8], patched: [UInt8]) {
        let v = try PatchStateTests.vector("wd 00.50 slot-16")
        let stock = V.element(v, size: 0x7_8000)
        let patched = try PatchedImage.apply(try V.edits(v), chip: .wd, to: stock)
        let below = [UInt8](repeating: 0x11, count: 0x8000), above = [UInt8](repeating: 0x22, count: 0x8_0000)
        let chip = FlashChip(flash: below + stock + above, sectors: ChipKind.display.flashSectors)
        return (chip, WritePlan(chip: .display, backup: stock, patched: patched), stock, patched)
    }

    static func app(_ chip: FlashChip) -> [UInt8] { chip.bytes(0x0800_8000, 0x7_8000) }

    @Test("A confirm for another plan writes nothing: not one request reaches the chip")
    func confirmIsForThisPlan() async throws {
        let (chip, plan, stock, _) = try Self.display()
        let other = WritePlan(chip: .display, backup: stock, patched: stock.enumerated().map { $0.offset == 0x10 ? 0 : $0.element })
        let outcome = await ChipWriter(transport: chip).write(plan, confirmed: Confirmation(typed: "UPDATE", for: other)!)
        #expect(outcome == .refused)
        #expect(chip.log.isEmpty)
    }

    @Test("Confirmed: the plan's sectors are erased and written, read back equal; nothing else on the chip changes")
    func writesAndVerifies() async throws {
        let (chip, plan, _, patched) = try Self.display()
        let before = chip.bytes(0x0800_0000, 0x10_0000)
        #expect(await ChipWriter(transport: chip).write(plan, confirmed: Confirmation(typed: "UPDATE", for: plan)!) == .written)
        #expect(Self.app(chip) == patched)
        let after = chip.bytes(0x0800_0000, 0x10_0000)
        let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }.map { 0x0800_0000 + UInt32($0.offset) }
        #expect(changed.allSatisfy { a in plan.sectors.contains { a >= $0.address && a < $0.address + UInt32($0.bytes.count) } })
        let erased = chip.log.filter { $0.request == 1 && $0.value == 0 && $0.data.first == 0x41 }.map { Array($0.data.dropFirst()) }
        #expect(erased == [[0x00, 0x80, 0x00, 0x08], [0x00, 0x00, 0x06, 0x08]])
    }

    @Test("A byte that reads back wrong: a mismatch at its address, and the owner can restore")
    func mismatch() async throws {
        let (chip, plan, stock, _) = try Self.display()
        chip.stuckAt = 0x0800_BDA4
        #expect(await ChipWriter(transport: chip).write(plan, confirmed: Confirmation(typed: "UPDATE", for: plan)!) == .mismatch(at: 0x0800_BDA4))
        chip.stuckAt = nil
        #expect(await ChipWriter(transport: chip).write(plan.restore, confirmed: Confirmation(restoring: plan.restore)!) == .written)
        #expect(Self.app(chip) == stock)
    }

    @Test("Restore after a good write: the backup's bytes again in the same sectors")
    func restore() async throws {
        let (chip, plan, stock, _) = try Self.display()
        _ = await ChipWriter(transport: chip).write(plan, confirmed: Confirmation(typed: "UPDATE", for: plan)!)
        #expect(await ChipWriter(transport: chip).write(plan.restore, confirmed: Confirmation(restoring: plan.restore)!) == .written)
        #expect(Self.app(chip) == stock)
    }

    @Test("The chip stops answering mid-update: no answer, so the owner is pointed to the recovery guide")
    func noAnswer() async throws {
        let (chip, plan, _, _) = try Self.display()
        chip.goneAfterErases = 1
        #expect(await ChipWriter(transport: chip).write(plan, confirmed: Confirmation(typed: "UPDATE", for: plan)!) == .noAnswer)
    }

    @Test("The write guard: another sector's erase, a block that isn't the plan's, or one past its sector never reach the chip")
    func guardRefuses() async throws {
        let (chip, plan, _, _) = try Self.display()
        let guarded = PlanTransport(chip, plan: plan)
        func dnload(_ value: UInt16, _ data: [UInt8]) async -> Bool {
            (try? await guarded.control(DFURequest(requestType: 0x21, request: 1, value: value, index: 0, data: data))) != nil
        }
        #expect(await !dnload(0, [0x41, 0x00, 0x00, 0x02, 0x08]))   // erase 0x08020000: not in the plan
        #expect(await !dnload(0, [0x41]))                           // a mass erase
        #expect(await !dnload(2, Array(plan.sectors[0].bytes[0..<16])))  // a block before any pointer
        #expect(chip.log.isEmpty)
        #expect(await dnload(0, [0x21, 0x00, 0x80, 0x00, 0x08]))    // the pointer to the plan's first sector
        var wrong = Array(plan.sectors[0].bytes[0..<16])
        wrong[0] ^= 0xFF
        #expect(await !dnload(2, wrong))                             // not the plan's bytes
        #expect(await !dnload(UInt16(2 + 0x4000 / 2048), [0xFF]))    // past the 16 KB sector
        #expect(await dnload(2, Array(plan.sectors[0].bytes[0..<2048])))
        #expect(chip.log.count == 2)
    }
}
