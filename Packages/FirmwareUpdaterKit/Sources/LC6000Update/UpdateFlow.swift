// What the LC6000 section offers and says through an update (#693; wording cos OK'd, 2026-11-22). The plan is built
// only from a backup taken this session, of this chip. A restore that doesn't read back right goes to the recovery
// guide, never round again.
import FirmwareCatalog
import Foundation
import UnitCheck

public struct UpdateFlow: Sendable {
    public let chip: ChipKind
    public let state: PatchState
    /// What would be written: nil unless the backup is this chip's and its firmware is the stock the patch is for.
    public let plan: WritePlan?
    private let fresh: Bool
    private var phase = Phase.ready

    enum Phase: Equatable { case ready, mismatch(UInt32), done(String), recovery }

    /// The written recovery guide, in the repo: the fallback when the app's own copy is missing.
    public static let recoveryGuideURL = URL(string: "https://github.com/ericdahl-dev/deckbridge/blob/main/docs/LC6000-RECOVERY.md")!

    /// `backup`: the read the plan is built from. `backupTakenThisSession`: it was read in this run of the app.
    public init(chip: ChipKind, backup: ChipRead?, backupTakenThisSession: Bool, edits: [PatchEdit], known: KnownNumbers) {
        self.chip = chip
        fresh = backupTakenThisSession
        guard let backup, backup.kind == chip else {
            state = .unknown
            plan = nil
            return
        }
        let catalogChip: Chip = chip == .display ? .wd : .tp
        state = PatchedImage.state(of: backup.app, chip: catalogChip, edits: edits, known: known)
        if case .stock = state, let patched = try? PatchedImage.apply(edits, chip: catalogChip, to: backup.app) {
            plan = WritePlan(chip: chip, backup: backup.app, patched: patched)
        } else {
            plan = nil
        }
    }

    #if DEBUG
    /// A screenshot preview's flow (#762): a made-up plan on a made-up backup, never from a chip. Debug builds only.
    public init(preview plan: WritePlan, version: String) {
        chip = plan.chip
        fresh = true
        state = .stock(version)
        self.plan = plan
    }
    #endif

    var name: String { chip == .display ? "display chip" : "top panel chip" }

    /// The confirm can be pressed: a plan from this session's backup, and nothing written yet.
    public var canConfirm: Bool { phase == .ready && fresh && plan.map { !$0.sectors.isEmpty } == true }
    public var confirmTitle: String { "Write to the LC6000's \(name)?" }
    public var confirmButton: String { "Write to the \(name)" }
    /// The risk first, in plain words (#762), and the word to type. No addresses: those are `confirmDetails`.
    public var confirmBody: String {
        "If it goes wrong, the LC6000 may not start, and the worst case needs a hardware probe. Your backup stays on "
            + "this Mac. Keep it on and plugged in until it's done.\n\nType \(Confirmation.word) to write."
    }
    /// While a write or restore runs (#762). The top panel chip's time is the owner's write (2026-11-22, about 30 s);
    /// the display chip's isn't measured yet.
    public var writingText: String {
        "Writing the \(name). Don't unplug or switch off the LC6000. "
            + (chip == .topPanel ? "This takes about 30 seconds." : "This takes under a minute.")
    }

    /// Exactly what is written where, behind the confirm's Details.
    public var confirmDetails: String { plan?.text ?? "" }

    /// After a mismatch: the backup's bytes back in the same sectors.
    public var canRestore: Bool { if case .mismatch = phase { true } else { false } }
    public var restoreButton: String { "Restore backup" }
    public var restorePlan: WritePlan? { plan?.restore }

    /// The guide, when the chip may not start: the app's own copy (`bundled`, #762: no network needed), else GitHub's.
    public func recoveryGuide(bundled: URL?) -> URL? { phase == .recovery ? bundled ?? Self.recoveryGuideURL : nil }

    public var status: String? {
        switch phase {
        case .ready:
            if case .alreadyPatched(let version) = state { return "Up to date: \(version) with this app's patch" }
            return nil
        case .mismatch(let at):
            return "The chip read back different at \(WritePlan.hex(at)), so the update didn't take. Restore your backup now."
        case .done(let text): return text
        case .recovery:
            return "The chip stopped answering during the update, so the LC6000 may not start. Leave it plugged in and "
                + "follow the recovery guide."
        }
    }

    /// The backup's result line, agreeing with this flow: a chip that already runs this app's patch is said to, not
    /// called firmware the app doesn't know (its hash or CRC is no longer stock's).
    public func backupLine(files: Int, identified: Identified?) -> String {
        var lines = ["Backup saved: read twice and the same, \(files) files."]
        let chipName = chip == .display ? "Display chip" : "Top panel chip"
        if case .alreadyPatched(let version) = state {
            lines.append("\(chipName): firmware \(version), with this app's patch.")
        } else if let found = identified {
            if let version = found.version {
                lines.append("\(chipName): firmware \(version)\(found.ours ? ", with DeckBridge's changes already on it" : "").")
            }
            if let refusal = found.refusal { lines.append(refusal) }
        }
        return lines.joined(separator: "\n")
    }

    /// The writer's outcome: of the update, or of the restore after a mismatch.
    public mutating func finished(_ outcome: WriteOutcome) {
        switch (phase, outcome) {
        case (_, .refused): break
        case (.ready, .written): phase = .done("Written and checked. Turn the LC6000 off and on again.")
        case (.ready, .mismatch(let at)): phase = .mismatch(at)
        case (.mismatch, .written): phase = .done("Your backup is back on the chip and checked. Turn the LC6000 off and on again.")
        case (.ready, .noAnswer), (.mismatch, .noAnswer), (.mismatch, .mismatch): phase = .recovery
        case (.done, _), (.recovery, _): break
        }
    }
}
