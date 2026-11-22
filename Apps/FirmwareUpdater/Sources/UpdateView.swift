// The LC6000 update (#693): after a backup this session, the confirm naming the chip and the risk, then the write,
// read-back and, on a mismatch, Restore backup. Not unit-tested: the rules are FirmwareUpdaterKit's LC6000Update;
// on a unit, the owner runs every write, with DeckBridge quit.
import FirmwareCatalog
import LC6000Update
import SwiftUI
import UnitCheck

@MainActor @Observable
final class UpdateModel {
    private(set) var flow: UpdateFlow
    private(set) var running = false
    /// Why a write didn't start (DeckBridge running, the chip not found): nothing was sent.
    private(set) var stop: String?
    var confirming = false

    /// `read`: the backup read just taken, in this run of the app.
    init(read: ChipRead) {
        let catalog = try? Catalog.builtIn()
        let chip: Chip = read.kind == .display ? .wd : .tp
        let edits = catalog.map { catalog in
            catalog.patchSetFirmwares.compactMap { catalog.patchSet(for: $0) }
                .flatMap(\.entries).filter { $0.kind == .patch && $0.chip == chip }.flatMap(\.edits)
        } ?? []
        flow = UpdateFlow(chip: read.kind, backup: read, backupTakenThisSession: true, edits: edits,
                          known: catalog?.knownNumbers ?? .none)
    }

    func write() async { await run(flow.plan) }
    func restore() async { await run(flow.restorePlan) }

    private func run(_ plan: WritePlan?) async {
        guard let plan, !running else { return }
        stop = nil
        if let reason = await Preflight(apps: WorkspaceApps()).stop() {
            stop = reason
            return
        }
        let found = IOKitDFU.devices()
        guard case .one(let kind, _) = UpdateModeDevices.judge(found.map(\.device)), kind == flow.chip,
              let one = found.first, let usb = try? IOUSBHostDFU(service: one.service) else {
            stop = "The same chip isn't in update mode on its own, so nothing was written."
            return
        }
        running = true
        defer { running = false }
        let outcome = await ChipWriter(transport: usb).write(plan, confirmed: Confirmation(plan))
        flow.finished(outcome)
        FileLog.shared.log("LC6000 \(flow.chip == .display ? "display" : "top panel") chip: update \(Self.word(outcome))")
    }

    /// The log's fixed words: never bytes or addresses beyond the outcome.
    static func word(_ outcome: WriteOutcome) -> String {
        switch outcome {
        case .written: "written and read back equal"
        case .mismatch: "read back different"
        case .noAnswer: "the chip stopped answering"
        case .refused: "not sent"
        }
    }
}

struct UpdateView: View {
    @Bindable var model: UpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Update the chip").font(.headline)
            if let status = model.flow.status { Text(status).fixedSize(horizontal: false, vertical: true) }
            if let stop = model.stop { Text(stop).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if model.flow.canConfirm {
                    Button(model.flow.confirmButton + "…") { model.confirming = true }.disabled(model.running)
                }
                if model.flow.canRestore {
                    Button(model.flow.restoreButton) { Task { await model.restore() } }.disabled(model.running)
                }
                if let guide = model.flow.recoveryGuide { Link("Recovery guide", destination: guide) }
                if model.running { ProgressView().controlSize(.small) }
            }
        }
        .padding(.top, 4)
        .alert(model.flow.confirmTitle, isPresented: $model.confirming) {
            Button(model.flow.confirmButton, role: .destructive) { Task { await model.write() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.flow.confirmBody)
        }
    }
}
