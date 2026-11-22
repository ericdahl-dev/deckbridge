import DeviceFinder
import FirmwareCatalog
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
/// Updates over the cable (#687) use the built-in catalog's panel image, the flashing serial port, and DeckBridge's
/// port handoff (#710). With no panel image in the catalog, no update is offered.
@MainActor
enum Live {
    static let usbChanges = IOKitUSBChanges()
    static func updater() -> Updater {
        let usb = IOKitUSB()
        let finder = DeviceFinder(usb: usb, midi: CoreMIDINames(), serial: ListeningSerial(), log: FileLog.shared)
        let flasher = (try? Catalog.builtIn()).map {
            CatalogFlasher(catalog: $0, usb: usb, finder: finder, opener: FlashingSerialOpener())
        }
        return Updater(finder: finder, changes: usbChanges.changes, log: FileLog.shared, borrow: DeckBridgeHandoff.borrow,
                       flasher: flasher)
    }
}

struct UpdaterView: View {
    let model: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionView(title: "Deck panel", section: model.screen.panel, accept: nil)
            PanelUpdateView(model: model)
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

/// Updating the panel over its cable (#687): the offer, each step while it runs with Cancel, then the result.
struct PanelUpdateView: View {
    let model: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.updating {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.screen.update ?? "")
                    Spacer()
                    Button("Cancel") { model.cancelUpdate() }
                }
            } else {
                if let text = model.screen.update { Text(text).fixedSize(horizontal: false, vertical: true) }
                if let offer = model.screen.panelUpdate {
                    if let note = offer.note { Text(note).foregroundStyle(.secondary) }
                    Button("Update the panel to \(offer.version)") { Task { await model.updatePanel() } }
                        .disabled(model.looking)
                }
            }
        }
    }
}
