import DeviceFinder
import FirmwareCatalog
import FirmwareRelease
import Foundation
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
                    FileLog.shared.log(model.screen.firstLookLine)
                    if SmokeLaunch.isOn { SmokeLaunch.finish() }
                    await model.watch()
                }
                // Beside the devices, not after them: watch() runs until the app quits.
                .task { await model.loadFirmware() }
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
                changes: usbChanges.changes, log: FileLog.shared, borrow: DeckBridgeHandoff.borrow,
                firmware: firmwareOffer)
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
    @State private var backup = BackupModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionView(title: "Deck panel", section: model.screen.panel, accept: nil)
            FirmwareRow(line: model.firmware)
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
