import DeviceFinder
import SwiftUI
import UpdaterScreen

@main
struct FirmwareUpdaterApp: App {
    @State private var model = Live.updater()

    var body: some Scene {
        Window("Firmware Updater", id: "updater") {
            UpdaterView(model: model)
                .frame(minWidth: 480, minHeight: 360)
                .task {
                    await model.refresh()
                    await model.watch()
                }
        }
        .windowResizability(.contentSize)
    }
}

/// The app's model, with the real ports: IOKit, CoreMIDI, a listen-only serial port, and IOKit's USB notifications.
@MainActor
enum Live {
    static let usbChanges = IOKitUSBChanges()
    static func updater() -> Updater {
        Updater(finder: DeviceFinder(usb: IOKitUSB(), midi: CoreMIDINames(), serial: ListeningSerial(), log: FileLog.shared),
                changes: usbChanges.changes, log: FileLog.shared, borrow: DeckBridgeHandoff.borrow)
    }
}

struct UpdaterView: View {
    let model: Updater
    @State private var backup = BackupModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionView(title: "Deck panel", section: model.screen.panel, accept: nil)
            SectionView(title: "LC6000", section: model.screen.lc6000, accept: model.acceptLC6000Warning)
            if model.screen.lc6000.warning == nil { BackupView(model: backup) }
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
                    if let guide = section.guide { GuideView(guide: guide) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Text(title).font(.title3.bold())
        }
    }
}

/// A driver's install steps, as plain numbered text, and the maker's download page (#688). No Settings button.
struct GuideView: View {
    let guide: DriverGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(guide.steps.enumerated()), id: \.offset) { number, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(number + 1).").monospacedDigit()
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
            Link("Open WCH's driver download page", destination: guide.link)
        }
        .padding(.top, 4)
    }
}
