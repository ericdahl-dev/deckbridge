import Foundation
import LC6000Update
import Testing
import UnitCheck

/// Installing block B (#751), end to end on a fake display chip: the check, this session's backup of B's area, the
/// owner's confirm, the write through #748's allowlisted writer, the read-back; a mismatch offers Restore, a chip that
/// stops answering points to the recovery guide.
@Suite("Block B: the install, on a fake chip")
struct BlockBFlowTests {
    /// The display chip: below the image 0x11, our app area with a hooked, known A, and erased flash above it.
    static func chip() -> FlashChip {
        let below = [UInt8](repeating: 0x11, count: 0x8000)
        let above = [UInt8](repeating: 0xFF, count: 0x8_0000)
        return FlashChip(flash: below + BlockBCheckTests.app() + above, sectors: ChipKind.display.flashSectors)
    }

    static func flow(_ chip: FlashChip, fresh: Bool = true, app: [UInt8]? = nil) throws -> BlockBFlow {
        BlockBFlow(b: try BlockBCheckTests.b(), app: app ?? BlockBCheckTests.app(), upper: chip.bytes(0x0808_0000, 0x8_0000),
                   backupTakenThisSession: fresh, known: BlockBCheckTests.known, log: BlockBCheckTests.Lines())
    }

    @Test("Ready, with this session's backup: the confirm names the display chip, the sectors and the risk")
    func confirm() throws {
        let flow = try Self.flow(Self.chip())
        #expect(flow.canConfirm)
        #expect(flow.confirmTitle == "Install block B on the LC6000's display chip?")
        #expect(flow.confirmButton == "Install block B")
        #expect(flow.confirmBody == flow.plan!.text + "\n\n" + """
            Block B is the drawing DeckBridge's own code on the display chip calls. Block A checks B's header, CRC and \
            layout before it calls anything in it, and stays silent for a B that fails them; a write cut off partway \
            fails B's CRC. If the chip stops answering, follow the recovery guide. Your backup stays on this Mac. Quit DeckBridge first, and keep the LC6000 powered and \
            plugged in until it's done.
            """)
    }

    @Test("A refused check: no confirm, and the screen says why")
    func refused() throws {
        let flow = try Self.flow(Self.chip(), app: BlockBCheckTests.app(hooked: false))
        #expect(!flow.canConfirm)
        #expect(flow.plan == nil)
        #expect(flow.status?.hasPrefix("The display chip doesn't carry DeckBridge's block A") == true)
    }

    @Test("A read of B's area that isn't the whole 512 KB: no confirm, and the screen says why")
    func shortRead() throws {
        let chip = Self.chip()
        let flow = BlockBFlow(b: try BlockBCheckTests.b(), app: BlockBCheckTests.app(), upper: chip.bytes(0x0808_0000, 0x1000),
                              backupTakenThisSession: true, known: BlockBCheckTests.known, log: BlockBCheckTests.Lines())
        #expect(!flow.canConfirm)
        #expect(flow.status == "The read of block B's area was short, so block B can't be installed. Back the chip up again.")
    }

    @Test("No confirm without a backup of B's area taken this session")
    func notFresh() throws {
        #expect(!(try Self.flow(Self.chip(), fresh: false)).canConfirm)
    }

    @Test("Confirmed and written: B at 0x08080000, read back equal, and not one byte below it changed")
    func written() async throws {
        let chip = Self.chip()
        let below = chip.bytes(0x0800_0000, 0x8_0000)
        var flow = try Self.flow(chip)
        let plan = flow.plan!
        let outcome = await ChipWriter(transport: chip).write(plan, confirmed: Confirmation(plan))
        #expect(outcome == .written)
        flow.finished(outcome)
        let b = try BlockBCheckTests.b()
        #expect(chip.bytes(0x0808_0000, b.bytes.count) == b.bytes)
        #expect(chip.bytes(0x0800_0000, 0x8_0000) == below)
        #expect(flow.status == "Block B is installed and checked. Turn the LC6000 off and on again.")
        // Every erase the chip got was at 0x08080000 or above.
        let erases = chip.log.filter { $0.requestType == 0x21 && $0.request == 1 && $0.value == 0 && $0.data.first == 0x41 }
        #expect(!erases.isEmpty)
        #expect(erases.allSatisfy { UInt32($0.data[1]) | UInt32($0.data[2]) << 8 | UInt32($0.data[3]) << 16 | UInt32($0.data[4]) << 24 >= 0x0808_0000 })
    }

    @Test("Nothing reaches the chip before the confirm of this very plan")
    func noConfirm() async throws {
        let chip = Self.chip()
        let plan = try Self.flow(chip).plan!
        let other = WritePlan.blockB(try BlockBCheckTests.b(), backup: [UInt8](repeating: 0x00, count: 0x8_0000))
        #expect(await ChipWriter(transport: chip).write(plan, confirmed: Confirmation(other)) == .refused)
        #expect(chip.log.isEmpty)
    }

    @Test("Read back wrong: Restore puts the backup's B area back")
    func mismatch() async throws {
        let chip = Self.chip()
        chip.stuckAt = 0x0808_0004
        var flow = try Self.flow(chip)
        let plan = flow.plan!
        let outcome = await ChipWriter(transport: chip).write(plan, confirmed: Confirmation(plan))
        #expect(outcome == .mismatch(at: 0x0808_0004))
        flow.finished(outcome)
        #expect(flow.canRestore)
        #expect(flow.restorePlan?.sectors.map(\.address) == [0x0808_0000])
        chip.stuckAt = nil
        let restore = flow.restorePlan!
        let back = await ChipWriter(transport: chip).write(restore, confirmed: Confirmation(restore))
        flow.finished(back)
        #expect(chip.bytes(0x0808_0000, 0x2_0000) == [UInt8](repeating: 0xFF, count: 0x2_0000))
        #expect(flow.status == "Your backup of block B's area is back on the chip and checked. Turn the LC6000 off and on again.")
    }

    @Test("The chip stops answering: the recovery guide")
    func noAnswer() async throws {
        let chip = Self.chip()
        chip.goneAfterErases = 0
        var flow = try Self.flow(chip)
        let plan = flow.plan!
        flow.finished(await ChipWriter(transport: chip).write(plan, confirmed: Confirmation(plan)))
        #expect(flow.recoveryGuide == UpdateFlow.recoveryGuideURL)
        #expect(!flow.canRestore)
    }
}
