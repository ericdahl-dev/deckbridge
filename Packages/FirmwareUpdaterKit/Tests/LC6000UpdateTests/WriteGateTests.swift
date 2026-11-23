import LC6000Update
import Testing
import UnitCheck

/// The owner's decision (#762, 2026-11-22): the typed word UPDATE guards the flash write, not the update-mode step.
/// Without it there's no confirmation, so the writer can't be asked. Restore after a mismatch is a click and confirm.
@Suite("LC6000 update: the typed UPDATE guards the write")
struct WriteGateTests {
    typealias W = ChipWriterTests

    @Test("UPDATE in any case gives the write's confirmation", arguments: ["UPDATE", "update", "Update", " UPDATE "])
    func typed(word: String) throws {
        let (_, plan, _, _) = try W.display()
        #expect(Confirmation(typed: word, for: plan) != nil)
    }

    @Test("Anything else gives none", arguments: ["", "UPDAT", "UPDATES", "yes", "U P D A T E"])
    func notTyped(word: String) throws {
        let (_, plan, _, _) = try W.display()
        #expect(Confirmation(typed: word, for: plan) == nil)
    }

    @Test("Restore's confirmation is only for a restore plan: never for the update's own write")
    func restoreOnly() throws {
        let (_, plan, _, _) = try W.display()
        #expect(Confirmation(restoring: plan) == nil)
        #expect(Confirmation(restoring: plan.restore) != nil)
        #expect(Confirmation(typed: "UPDATE", for: plan.restore) == nil)
    }

    @Test("With the word: written. Without it the flow offers no confirmation, and not one request reaches the chip")
    func endToEnd() async throws {
        let (chip, plan, _, _) = try W.display()
        if let confirmed = Confirmation(typed: "", for: plan) { _ = await ChipWriter(transport: chip).write(plan, confirmed: confirmed) }
        #expect(chip.log.isEmpty)
        let confirmed = try #require(Confirmation(typed: "update", for: plan))
        #expect(await ChipWriter(transport: chip).write(plan, confirmed: confirmed) == .written)
    }
}
