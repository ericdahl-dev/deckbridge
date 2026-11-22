import AppKit
import FirmwareCatalog
import SwiftUI
import UnitCheck

/// The LC6000 section's unit check and backup (#692): the owner puts one chip in update mode, picks a folder, and the
/// app reads the chip twice and saves it. The backup writes nothing to the unit; an update (#693) writes only after its confirm.
@MainActor @Observable
final class BackupModel {
    private(set) var running = false
    private(set) var result: String?
    var typed = ""
    private(set) var stepResult: String?
    /// The update this session's backup allows (#693); nil until a backup is saved.
    private(set) var update: UpdateModel?
    /// Block B's install (#751): display chip only, and only when this app carries block B.
    private(set) var blockB: BlockBModel?

    /// The display chip's step into update mode: only on the owner's typed UPDATE, once.
    func enterUpdateMode() async {
        let outcome = await UpdateModeStep(midi: CoreMIDISend(), apps: WorkspaceApps()).enter(typed: typed)
        typed = ""
        switch outcome {
        case .sent: stepResult = "Sent. The display chip restarts in update mode: give it a few seconds, then back it up. It stays in update mode until it's flashed; whether a power cycle ends it isn't known yet. Denon's own updater flashes a chip in update mode, so it is the way back."
        case .refused(let reason): stepResult = reason
        }
    }

    func backUp() async {
        guard !running else { return }
        if let stop = await Preflight(apps: WorkspaceApps()).stop() {
            result = stop
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save backup here"
        panel.message = "Pick a folder on this Mac, outside any git repository."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        running = true
        defer { running = false }
        let found = IOKitDFU.devices()
        guard found.count == 1, let one = found.first, let usb = try? IOUSBHostDFU(service: one.service) else {
            let report = await UnitCheck(known: Self.known, log: FileLog.shared)
                .backUp(devices: found.map(\.device), transport: Unreachable(), into: folder, stamp: Self.stamp())
            result = report.refusal ?? "The chip in update mode couldn't be opened. Nothing was read."
            return
        }
        let stamp = Self.stamp()
        let report = await UnitCheck(known: Self.known, log: FileLog.shared)
            .backUp(devices: [one.device], transport: ReadOnlyTransport(usb), into: folder, stamp: stamp)
        update = report.read.map { UpdateModel(read: $0) }
        // With a read, the update's view of it: a chip already running this app's patch is said to (#748).
        result = update.map { $0.flow.backupLine(files: report.files.count, identified: report.identified) } ?? Self.text(report)
        blockB = nil
        if let read = report.read, read.kind == .display {
            let (model, problem) = await BlockBModel.make(app: read.app, reader: DFUReader(transport: ReadOnlyTransport(usb)),
                                                          folder: folder, stamp: stamp)
            blockB = model
            if let problem { result = (result.map { $0 + "\n" } ?? "") + problem }
        }
    }

    static var known: KnownFirmware {
        let numbers = (try? Catalog.builtIn().knownNumbers) ?? KnownNumbers.none
        return KnownFirmware(display: numbers.display, topPanel: numbers.topPanel)
    }

    static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        format.locale = Locale(identifier: "en_US_POSIX")
        return format.string(from: Date())
    }

    static func text(_ report: UnitCheck.Result) -> String {
        if let refusal = report.refusal { return refusal }
        var lines = ["Backup saved: read twice and the same, \(report.files.count) files."]
        if let found = report.identified {
            let chip = found.kind == .display ? "Display chip" : "Top panel chip"
            if let version = found.version {
                lines.append("\(chip): firmware \(version)\(found.ours ? ", with DeckBridge's changes already on it" : "").")
            }
            if let refusal = found.refusal { lines.append(refusal) }
        }
        return lines.joined(separator: "\n")
    }
}

/// Never asked: the check refuses before any read when the device list isn't exactly one chip.
private struct Unreachable: DFUTransport {
    func control(_ request: DFURequest) async throws -> [UInt8] { throw DFUError.left }
}

struct BackupView: View {
    @Bindable var model: BackupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Back up a chip").font(.headline)
            Text("Put one chip in update mode. Top panel chip: power the LC6000 off, then hold BACK + FWD + VINYL while you power it on.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Display chip: it has no buttons. One MIDI message restarts it in update mode. It writes nothing to its firmware. Type UPDATE to send it.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Type UPDATE", text: $model.typed).frame(maxWidth: 140)
                Button("Send the update-mode message") { Task { await model.enterUpdateMode() } }
                    .disabled(model.typed != "UPDATE" || model.running)
            }
            if let stepResult = model.stepResult { Text(stepResult).fixedSize(horizontal: false, vertical: true) }
            Text("Then quit DeckBridge and pick a folder. The app reads the chip twice and saves it only if both reads match. Nothing is written to the LC6000.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            HStack {
                Button("Back up the chip in update mode…") { Task { await model.backUp() } }
                    .disabled(model.running)
                if model.running { ProgressView().controlSize(.small) }
            }
            if let result = model.result { Text(result).fixedSize(horizontal: false, vertical: true) }
            if let update = model.update { UpdateView(model: update) }
            if let blockB = model.blockB { BlockBView(model: blockB) }
        }
        .padding(.top, 4)
    }
}
