import AppKit
import FirmwareCatalog
import SwiftUI
import UnitCheck
import UpdaterScreen

/// The LC6000 section's unit check and backup (#692): the owner puts one chip in update mode, picks a folder, and the
/// app reads the chip twice and saves it. The backup writes nothing to the unit; an update (#693) writes only after its confirm.
@MainActor @Observable
final class BackupModel {
    private(set) var running = false
    /// The step's and the backup's lines (#762): a step starting clears the stale ones.
    private(set) var lines = LC6000Lines()
    var result: String? { lines.backup }
    var stepResult: String? { lines.step }
    /// The update-mode step's confirm is showing (#762: a click and a confirm, no typed word).
    var confirmingStep = false
    /// The update this session's backup allows (#693); nil until a backup is saved.
    private(set) var update: UpdateModel?
    /// A screenshot preview's model (#761): its buttons do nothing, so no MIDI message is sent and no chip is read.
    private var inert = false

    init() {}

    #if DEBUG
    init(preview result: String?) {
        lines.backup = result
        inert = true
    }
    #endif

    /// The display chip's step into update mode: only from the confirm's own button, once.
    func enterUpdateMode(clicked button: String) async {
        guard !inert, let confirmed = UpdateModeStep.Confirmed(clicked: button) else { return }
        lines.stepStarts()
        let outcome = await UpdateModeStep(midi: CoreMIDISend(), apps: WorkspaceApps()).enter(confirmed: confirmed)
        switch outcome {
        case .sent: lines.step = UpdateModeStep.sentText
        case .refused(let reason): lines.step = reason
        }
    }

    func backUp() async {
        guard !running, !inert else { return }
        lines.backupStarts()
        if let stop = await Preflight(apps: WorkspaceApps()).stop() {
            lines.backup = stop
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
            lines.backup = report.refusal ?? "The chip in update mode couldn't be opened. Nothing was read."
            return
        }
        let report = await UnitCheck(known: Self.known, log: FileLog.shared)
            .backUp(devices: [one.device], transport: ReadOnlyTransport(usb), into: folder, stamp: Self.stamp())
        update = report.read.map { UpdateModel(read: $0) { [weak self] in self?.lines.writeStarts() } }
        // With a read, the update's view of it: a chip already running this app's patch is said to (#748).
        lines.backup = update.map { $0.flow.backupLine(files: report.files.count, identified: report.identified) } ?? Self.text(report)
    }

    static var known: KnownFirmware {
        let numbers = (try? Catalog.builtIn().knownNumbers) ?? KnownNumbers.none
        return KnownFirmware(display: numbers.display, topPanel: numbers.topPanel, displayOurs: numbers.displayOurs)
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
            // The steps in order (#762), DeckBridge quit first.
            ForEach(Array(UpdaterScreen.lc6000Steps.prefix(3).enumerated()), id: \.offset) { _, step in
                Text(step).fixedSize(horizontal: false, vertical: true)
            }
            Button("Restart the display chip in update mode…") { model.confirmingStep = true }
                .disabled(model.running)
            if let stepResult = model.stepResult { Text(stepResult).fixedSize(horizontal: false, vertical: true) }
            Text(UpdaterScreen.lc6000Steps[3])
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            HStack {
                Button("Back up the chip in update mode…") { Task { await model.backUp() } }
                    .disabled(model.running)
                if model.running { ProgressView().controlSize(.small) }
            }
            if let result = model.result { Text(result).fixedSize(horizontal: false, vertical: true) }
            if let update = model.update { UpdateView(model: update) }
        }
        .padding(.top, 4)
        // Return never fires it: Cancel is the default.
        .alert(UpdateModeStep.confirmTitle, isPresented: $model.confirmingStep) {
            Button(UpdateModeStep.confirmButton) { Task { await model.enterUpdateMode(clicked: UpdateModeStep.confirmButton) } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text(UpdateModeStep.confirmBody)
        }
    }
}
