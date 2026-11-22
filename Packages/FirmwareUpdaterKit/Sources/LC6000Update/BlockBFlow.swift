// What the LC6000 section offers and says through a block B install (#751), as UpdateFlow does for a patch (#693):
// the check first (reads only), a plan only from this session's backup of B's area, the owner's confirm, then
// #748's writer. A restore that doesn't read back right goes to the recovery guide, never round again.
import DeviceFinder
import Foundation

public struct BlockBFlow: Sendable {
    public let check: BlockBCheck
    /// What would be written: nil unless the check is ready.
    public let plan: WritePlan?
    private let fresh: Bool
    private var phase = Phase.ready

    enum Phase: Equatable { case ready, mismatch(UInt32), done(String), recovery }

    /// `app`: the display chip's app area, from the unit check's read. `upper`: B's area, 0x08080000-0x080FFFFF, from
    /// Backup.upper. `backupTakenThisSession`: both were read in this run of the app.
    public init(b: BlockB, app: [UInt8], upper: [UInt8], backupTakenThisSession: Bool,
                known: [KnownBlockA] = KnownBlockA.shipped, log: any LogSink) {
        fresh = backupTakenThisSession
        check = BlockBCheck.check(app: app, b: b, known: known, log: log)
        plan = check == .ready && upper.count == BlockB.limit ? WritePlan.blockB(b, backup: upper) : nil
    }

    public var canConfirm: Bool { phase == .ready && fresh && plan.map { !$0.sectors.isEmpty } == true }
    public var confirmTitle: String { "Install block B on the LC6000's display chip?" }
    public var confirmButton: String { "Install block B" }
    /// The risk: the kit's tests (tools/lc6000-display-fw/arm/test/test_block.py) show stock's render runs with or
    /// without our code, and block A stays silent for a corrupted B or one of another layout. A cut-off write fails
    /// B's CRC because the header, with the CRC over B's whole length, is in sector 8, written first (inferred, untested).
    public var confirmBody: String {
        (plan?.text ?? "") + "\n\n" + "Block B is the drawing DeckBridge's own code on the display chip calls. Block A "
            + "checks B's header, CRC and layout before it calls anything in it, and stays silent for a B that fails them; "
            + "a write cut off partway fails B's CRC. If the chip stops answering, follow the recovery guide. Your backup "
            + "stays on this Mac. Quit DeckBridge first, and keep the LC6000 powered and plugged in until it's done."
    }

    public var canRestore: Bool { if case .mismatch = phase { true } else { false } }
    public var restoreButton: String { "Restore backup" }
    public var restorePlan: WritePlan? { plan?.restore }

    public var recoveryGuide: URL? { phase == .recovery ? UpdateFlow.recoveryGuideURL : nil }

    public var status: String? {
        switch phase {
        case .ready:
            if case .refused(let reason) = check { return reason }
            if plan == nil { return "The read of block B's area was short, so block B can't be installed. Back the chip up again." }
            if plan?.sectors.isEmpty == true { return "Up to date: this block B is already on the display chip." }
            return nil
        case .mismatch(let at):
            return "The chip read back different at \(WritePlan.hex(at)), so block B didn't take. Restore your backup now."
        case .done(let text): return text
        case .recovery:
            return "The chip stopped answering during the install. Leave the LC6000 plugged in and follow the recovery guide."
        }
    }

    public mutating func finished(_ outcome: WriteOutcome) {
        switch (phase, outcome) {
        case (_, .refused): break
        case (.ready, .written): phase = .done("Block B is installed and checked. Turn the LC6000 off and on again.")
        case (.ready, .mismatch(let at)): phase = .mismatch(at)
        case (.mismatch, .written):
            phase = .done("Your backup of block B's area is back on the chip and checked. Turn the LC6000 off and on again.")
        case (.ready, .noAnswer), (.mismatch, .noAnswer), (.mismatch, .mismatch): phase = .recovery
        case (.done, _), (.recovery, _): break
        }
    }
}
