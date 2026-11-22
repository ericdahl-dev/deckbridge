import DeviceFinder
import FirmwareCatalog
import FirmwareModel
import Foundation
import PanelFlasher

/// The app's flasher (#687): the catalog's newest deck panel image, put on the port the panel has on USB now. Wi-Fi
/// settings are kept (nvs isn't wiped), and a board without the deck panel's layout is refused, never converted.
public struct CatalogFlasher: PanelFlashing {
    let catalog: Catalog
    let usb: any USBDevices
    let update: PanelUpdate

    public init(catalog: Catalog, usb: any USBDevices, finder: DeviceFinder, opener: any LineOpener) {
        self.catalog = catalog
        self.usb = usb
        update = PanelUpdate(opener: opener, finder: finder)
    }

    public static let unknownBuildNote = "This panel runs a build this app doesn't know: a development build, or one newer than this app."

    public func offer(for build: PanelBuild) -> PanelUpdateOffer? {
        switch catalog.offer(for: build) {
        case .update(let newest): PanelUpdateOffer(version: newest.version.description, note: nil)
        case .unknownBuild(let newest): PanelUpdateOffer(version: newest.version.description, note: Self.unknownBuildNote)
        case .upToDate, .nothing: nil
        }
    }

    public func repairVersion() -> String? { catalog.newestPanel()?.version.description }

    public func flash(report: @escaping @Sendable (PanelUpdate.Step) -> Void) async {
        guard let port = DeviceFinder.panelPort(in: await usb.devices()) else { return report(.failed(.lineLost)) }
        guard let newest = catalog.newestPanel(), let image = try? Data(contentsOf: newest.image) else {
            return report(.failed(.notAPanelImage))
        }
        await update.run([UInt8](image), on: port, wipeWiFi: false, report: report)
    }
}
