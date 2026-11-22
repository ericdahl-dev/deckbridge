import DeviceFinder
import SwiftUI
import UpdaterScreen

@main
struct FirmwareUpdaterApp: App {
    @State private var model = UpdaterModel()

    var body: some Scene {
        Window("Firmware Updater", id: "updater") {
            UpdaterView(model: model)
                .frame(minWidth: 480, minHeight: 360)
                .task {
                    await model.refresh()
                    FileLog.shared.log(model.screen.firstLookLine)
                    if SmokeLaunch.isOn { SmokeLaunch.finish() }
                }
        }
        .windowResizability(.contentSize)
    }
}

/// Finds what is plugged in and keeps the screen's values. It only looks (#685).
@MainActor @Observable
final class UpdaterModel {
    private(set) var screen = UpdaterScreen(found: Found(), lc6000WarningAccepted: false)
    private(set) var looking = false
    private var found = Found()
    private var lc6000WarningAccepted = false
    private let finder = DeviceFinder(usb: IOKitUSB(), midi: CoreMIDINames(), serial: ListeningSerial(), log: FileLog.shared)

    func refresh() async {
        guard !looking else { return }
        looking = true
        found = await finder.find()
        looking = false
        show()
    }

    func acceptLC6000Warning() {
        lc6000WarningAccepted = true
        show()
    }

    private func show() {
        screen = UpdaterScreen(found: found, lc6000WarningAccepted: lc6000WarningAccepted)
    }
}

struct UpdaterView: View {
    let model: UpdaterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionView(title: "Deck panel", section: model.screen.panel, accept: nil)
            SectionView(title: "LC6000", section: model.screen.lc6000, accept: model.acceptLC6000Warning)
            HStack {
                Spacer()
                if model.looking { ProgressView().controlSize(.small) }
                Button("Look again") { Task { await model.refresh() } }
                    .disabled(model.looking)
            }
        }
        .padding(20)
    }
}

struct SectionView: View {
    let title: String
    let section: DeviceSection
    let accept: (() -> Void)?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let warning = section.warning {
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                    if let accept { Button("I understand", action: accept) }
                } else {
                    Text(section.status).font(.headline)
                    if let detail = section.detail { Text(detail).foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Text(title).font(.title3.bold())
        }
    }
}
