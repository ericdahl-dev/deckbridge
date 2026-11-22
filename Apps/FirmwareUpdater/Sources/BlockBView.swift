// Block B on the display chip (#751): after this session's backup, B's own area is read twice and saved too; then
// the check, the confirm naming the chip, the sectors and the risk, the write, the read-back and, on a mismatch,
// Restore backup. Not unit-tested: the rules are FirmwareUpdaterKit's LC6000Update (BlockBFlow); on a unit, the owner
// runs every write, with DeckBridge quit. Shown only when this app carries block B (the release's catalog does, #696).
import FirmwareCatalog
import Foundation
import LC6000Update
import SwiftUI
import UnitCheck

@MainActor @Observable
final class BlockBModel {
    private(set) var flow: BlockBFlow
    private(set) var running = false
    private(set) var stop: String?
    var confirming = false

    init(flow: BlockBFlow) { self.flow = flow }

    /// Block B as this app carries it, checked; nil when the catalog has none (a build without the release's blocks).
    static func carried() -> BlockB? {
        guard let catalog = try? Catalog.builtIn(),
              let blocks = catalog.patchSetFirmwares.compactMap({ catalog.patchSet(for: $0)?.blocks }).first,
              let data = try? Data(contentsOf: blocks.b) else { return nil }
        return try? BlockB([UInt8](data))
    }

    /// After the display chip's backup (`app`, this session's read): B's area read twice and saved beside it, then the
    /// flow. Reads only; nil when this app carries no block B.
    static func make(app: [UInt8], reader: DFUReader, folder: URL, stamp: String) async -> (BlockBModel?, String?) {
        guard let b = carried() else { return (nil, nil) }
        do {
            let upper = try await Backup.upper(reader: reader, into: folder, stamp: stamp)
            FileLog.shared.log("LC6000 display chip: block B's area backed up, read twice and the same")
            let flow = BlockBFlow(b: b, app: app, upper: upper.bytes, backupTakenThisSession: true, log: FileLog.shared)
            return (BlockBModel(flow: flow), nil)
        } catch let error as BackupError {
            return (nil, error.reason)
        } catch {
            return (nil, "Block B's area couldn't be read or saved, so block B can't be installed this time.")
        }
    }

    func install() async { await run(flow.plan) }
    func restore() async { await run(flow.restorePlan) }

    private func run(_ plan: WritePlan?) async {
        guard let plan, !running else { return }
        stop = nil
        if let reason = await Preflight(apps: WorkspaceApps()).stop() {
            stop = reason
            return
        }
        let found = IOKitDFU.devices()
        guard case .one(let kind, _) = UpdateModeDevices.judge(found.map(\.device)), kind == .display,
              let one = found.first, let usb = try? IOUSBHostDFU(service: one.service) else {
            stop = "The display chip isn't in update mode on its own, so nothing was written."
            return
        }
        running = true
        defer { running = false }
        let outcome = await ChipWriter(transport: usb).write(plan, confirmed: Confirmation(plan))
        flow.finished(outcome)
        FileLog.shared.log("LC6000 display chip: block B \(UpdateModel.word(outcome))")
    }
}

struct BlockBView: View {
    @Bindable var model: BlockBModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Block B, the drawing").font(.headline)
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
            Button(model.flow.confirmButton, role: .destructive) { Task { await model.install() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.flow.confirmBody)
        }
    }
}
