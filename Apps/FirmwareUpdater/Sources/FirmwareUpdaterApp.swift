import DeviceFinder
import FirmwareCatalog
import FirmwareRelease
import Foundation
import SwiftUI
import UpdaterScreen

@main
struct FirmwareUpdaterApp: App {
    @State private var model = Self.makeModel()

    var body: some Scene {
        Window("Firmware Updater", id: "updater") {
            UpdaterView(model: model)
                .task {
                    #if DEBUG
                    if let shot = PreviewLaunch.shot {
                        await PreviewLaunch.run(shot, on: model)
                        return
                    }
                    #endif
                    await model.refresh()
                    FileLog.shared.log(model.screen.firstLookLine)
                    if SmokeLaunch.isOn { SmokeLaunch.finish() }
                    await model.watch()
                }
                // Beside the devices, not after them: watch() runs until the app quits.
                .task { await model.loadFirmware() }
        }
    }

    /// The real ports, or in a Debug build started with --preview, a fixed state on fake ones (#761) and no real port
    /// made at all.
    @MainActor static func makeModel() -> Updater {
        #if DEBUG
        if let shot = PreviewLaunch.shot { return Updater.preview(shot.state) }
        #endif
        return Live.updater()
    }
}

/// The app's model, with the real ports: IOKit, CoreMIDI, a listen-only serial port, and IOKit's USB notifications.
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
                       firmware: firmwareOffer, flasher: flasher)
    }

    /// The firmware on offer (#704): this project's newest GitHub release if it checks out against the app's keys, else
    /// the firmware built into the app, and why. One fetch per launch; a checked release is kept in Application Support.
    @Sendable static func firmwareOffer() async -> FirmwareLine {
        guard let builtIn = try? Catalog.builtIn() else {
            return FirmwareLine(source: "The firmware built into this app can't be read", reason: nil)
        }
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let cache = support.appending(path: "dev.ericdahl.FirmwareUpdater/Releases")
        let offer = await FirmwareOffer.fetch(http: URLSessionHTTP(), over: builtIn, cache: cache)
        return FirmwareLine(source: offer.source, reason: offer.reason)
    }
}

struct UpdaterView: View {
    let model: Updater
    @State private var backup = Self.makeBackup()
    @State private var fitting = WindowFitting()

    static func makeBackup() -> BackupModel {
        #if DEBUG
        if let shot = PreviewLaunch.shot {
            return BackupModel(preview: shot.backupResult, confirmingStep: shot == .stepConfirm,
                               update: [.writeConfirm, .writing, .details].contains(shot)
                                   ? UpdateModel(preview: shot == .writing, details: shot == .details) : nil)
        }
        #endif
        return BackupModel()
    }

    /// The sections in a scroll view the window fits (#761): taller than the screen, they scroll, and new text at the
    /// bottom is kept in view.
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    sections
                    Color.clear.frame(height: 0).id(Self.end)
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    fitting.contentChanged(size)
                    scroll.scrollTo(Self.end, anchor: .bottom)
                }
            }
        }
        .frame(minWidth: WindowFit.minWidth, minHeight: 200)
        .background(WindowReader { fitting.attach($0) })
    }

    private static let end = "end"

    private var sections: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionView(title: "Deck panel", section: model.screen.panel, accept: nil)
            FirmwareRow(line: model.firmware)
            PanelUpdateView(model: model)
            // The LC6000's steps inside its box, only once one is found (#762).
            SectionView(title: "LC6000", section: model.screen.lc6000, accept: model.acceptLC6000Warning) {
                if model.screen.showsLC6000Steps { BackupView(model: backup) }
            }
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

struct SectionView<Extra: View>: View {
    let title: String
    let section: DeviceSection
    let accept: (() -> Void)?
    let extra: Extra

    init(title: String, section: DeviceSection, accept: (() -> Void)?, @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.section = section
        self.accept = accept
        self.extra = extra()
    }

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
                    extra
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Text(title).font(.title3.bold())
        }
    }
}

extension SectionView where Extra == EmptyView {
    init(title: String, section: DeviceSection, accept: (() -> Void)?) {
        self.init(title: title, section: section, accept: accept) { EmptyView() }
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

/// The firmware on offer (#704), on its own row: where it comes from and, if the newest release wasn't used, why.
struct FirmwareRow: View {
    let line: FirmwareLine?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let line {
                Text(line.source)
                if let reason = line.reason { Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking for newer firmware…").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Updating the panel over its cable (#687): the offer, each step while it runs with Cancel, then the result.
struct PanelUpdateView: View {
    let model: Updater
    @State private var confirmingRepair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.updating {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.screen.update ?? "")
                    Spacer()
                    Button("Cancel") { model.cancelUpdate() }
                        .disabled(!model.canCancel)
                }
                if let note = model.screen.cancelNote {
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if let text = model.screen.update { Text(text).fixedSize(horizontal: false, vertical: true) }
                if let offer = model.screen.panelUpdate {
                    if let note = offer.note { Text(note).foregroundStyle(.secondary) }
                    Button("Update the panel to \(offer.version)") { Task { await model.updatePanel() } }
                        .disabled(model.looking)
                }
                if let repair = model.screen.panelRepair {
                    Button("Repair the panel") { confirmingRepair = true }
                        .disabled(model.looking)
                        .confirmationDialog("Repair the panel?", isPresented: $confirmingRepair) {
                            Button("Repair: write \(repair.version)") { Task { await model.repairPanel() } }
                            Button("Not now", role: .cancel) {}
                        } message: {
                            Text(UpdaterScreen.repairConfirm(version: repair.version))
                        }
                }
            }
        }
    }
}
