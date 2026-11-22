import FirmwareCatalog
import Foundation
import LC6000Update
import Testing
import UnitCheck

/// What the LC6000 section offers and says through an update (#693, wording cos OK'd): an update only from a backup
/// taken this session of this chip, the confirm naming the chip and the risk, then the outcome. A restore that fails its
/// read-back goes to the recovery guide, never round again.
@Suite("LC6000 update: the screen through an update")
struct UpdateFlowTests {
    typealias V = PatchVectorTests

    static func flow(fresh: Bool = true, patched: Bool = false, kind: ChipKind = .display, knowsStock: Bool = true) throws -> UpdateFlow {
        let v = try PatchStateTests.vector("wd 00.50 slot-16")
        let stock = V.element(v, size: 0x7_8000)
        let edits = try V.edits(v)
        let app = patched ? try PatchedImage.apply(edits, chip: .wd, to: stock) : stock
        let known = knowsStock ? KnownNumbers(display: [try #require(DisplayTrailer.crc(of: stock)): "00.50"], topPanel: [:]) : .none
        let backup = ChipRead(kind: kind, settings: [], app: app)
        return UpdateFlow(chip: .display, backup: backup, backupTakenThisSession: fresh, edits: edits, known: known)
    }

    @Test("Stock, with this session's backup: the confirm says the risk first in plain words; the sectors are its Details")
    func confirm() throws {
        let flow = try Self.flow()
        #expect(flow.canConfirm)
        #expect(flow.confirmTitle == "Write to the LC6000's display chip?")
        #expect(flow.confirmButton == "Write to the display chip")
        #expect(flow.confirmBody == """
            If it goes wrong, the LC6000 may not start, and the worst case needs a hardware probe. Your backup stays on \
            this Mac. Keep it on and plugged in until it's done.

            Type UPDATE to write.
            """)
        #expect(!flow.confirmBody.contains("0x"))
        #expect(flow.confirmDetails == """
            The display chip: 2 flash sectors are erased and written with the patched image, 0x08008000-0x0800BFFF \
            (16 KB) and 0x08060000-0x0807FFFF (128 KB). 5 bytes differ from your backup. Every other sector is untouched.
            """)
    }

    @Test("No confirm without a backup taken this session of this chip")
    func staleOrOtherBackup() throws {
        #expect(try !Self.flow(fresh: false).canConfirm)
        #expect(try !Self.flow(kind: .topPanel).canConfirm)
        #expect(try Self.flow(kind: .topPanel).plan == nil)
        // Firmware the app doesn't know, though the patch's old bytes are there: no plan either.
        #expect(try Self.flow(knowsStock: false).plan == nil)
    }

    @Test("Already patched: up to date, and nothing to confirm")
    func upToDate() throws {
        let flow = try Self.flow(patched: true)
        #expect(flow.status == "Up to date: 00.50 with this app's patch")
        #expect(!flow.canConfirm)
    }

    @Test("Written and checked: power-cycle")
    func written() throws {
        var flow = try Self.flow()
        flow.finished(.written)
        #expect(flow.status == "Written and checked. Turn the LC6000 off and on again.")
        #expect(!flow.canConfirm && !flow.canRestore && flow.recoveryGuide == nil)
    }

    @Test("A mismatch offers Restore backup; restored and checked, power-cycle")
    func mismatchThenRestore() throws {
        var flow = try Self.flow()
        flow.finished(.mismatch(at: 0x0800_BDA4))
        #expect(flow.status == "The chip read back different at 0x0800BDA4, so the update didn't take. Restore your backup now.")
        #expect(flow.canRestore && flow.restoreButton == "Restore backup" && !flow.canConfirm)
        #expect(flow.restorePlan == flow.plan?.restore)
        flow.finished(.written)
        #expect(flow.status == "Your backup is back on the chip and checked. Turn the LC6000 off and on again.")
        #expect(!flow.canRestore)
    }

    @Test("A restore that reads back wrong, or a chip that stops answering: the recovery guide, and no button to go round again")
    func restoreFailsOrNoAnswer() throws {
        var flow = try Self.flow()
        flow.finished(.mismatch(at: 0x0800_BDA4))
        flow.finished(.mismatch(at: 0x0800_8000))
        let noAnswer = "The chip stopped answering during the update, so the LC6000 may not start. Leave it plugged in and follow the recovery guide."
        #expect(flow.status == noAnswer)
        #expect(!flow.canRestore && !flow.canConfirm)
        #expect(flow.recoveryGuide == URL(string: "https://github.com/ericdahl-dev/deckbridge/blob/main/docs/LC6000-RECOVERY.md"))
        var gone = try Self.flow()
        gone.finished(.noAnswer)
        #expect(gone.status == noAnswer && !gone.canRestore && gone.recoveryGuide != nil)
    }

    @Test("The owner's top panel chip after #748's run: patched, so its hash isn't stock's, and it shows up to date")
    func topPanelPatched() throws {
        let v = try PatchStateTests.vector("tp 00.31")
        let stock = V.element(v) + [UInt8](repeating: 0xFF, count: 0x3_8000 - 0xE000)
        let edits = try V.edits(v)
        let patched = try PatchedImage.apply(edits, chip: .tp, to: stock)
        let known = KnownNumbers(display: [:], topPanel: [PatchStateTests.sha(stock): "00.31"])
        let flow = UpdateFlow(chip: .topPanel, backup: ChipRead(kind: .topPanel, settings: [], app: patched),
                              backupTakenThisSession: true, edits: edits, known: known)
        #expect(flow.status == "Up to date: 00.31 with this app's patch")
        #expect(!flow.canConfirm)
    }

    @Test("The backup's line agrees: a patched chip isn't firmware the app doesn't know")
    func backupLine() throws {
        let v = try PatchStateTests.vector("tp 00.31")
        let stock = V.element(v) + [UInt8](repeating: 0xFF, count: 0x3_8000 - 0xE000)
        let edits = try V.edits(v)
        let read = ChipRead(kind: .topPanel, settings: [], app: try PatchedImage.apply(edits, chip: .tp, to: stock))
        let known = KnownNumbers(display: [:], topPanel: [PatchStateTests.sha(stock): "00.31"])
        let flow = UpdateFlow(chip: .topPanel, backup: read, backupTakenThisSession: true, edits: edits, known: known)
        let unknown = Identified(kind: .topPanel, version: nil, refusal: "The top panel chip runs firmware this app doesn't know. Updates are off; a backup is still allowed.")
        #expect(flow.backupLine(files: 2, identified: unknown)
            == "Backup saved: read twice and the same, 2 files.\nTop panel chip: firmware 00.31, with this app's patch.")
        let stockFlow = UpdateFlow(chip: .topPanel, backup: ChipRead(kind: .topPanel, settings: [], app: stock),
                                   backupTakenThisSession: true, edits: edits, known: known)
        let found = Identified(kind: .topPanel, version: "00.31", refusal: nil)
        #expect(stockFlow.backupLine(files: 2, identified: found)
            == "Backup saved: read twice and the same, 2 files.\nTop panel chip: firmware 00.31.")
    }
}
