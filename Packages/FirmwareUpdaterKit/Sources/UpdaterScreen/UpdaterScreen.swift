import DeviceFinder
import Foundation

/// Steps to install a missing USB driver (#688): plain text, and the maker's own download page.
public struct DriverGuide: Sendable, Equatable {
    public let steps: [String]
    public let link: URL

    /// WCH's CH34x driver for the panel's CH340K. The page was checked by hand on 2026-11-21: WCH's own site,
    /// CH34XSER_MAC.ZIP version 2.1, for CH340 and macOS 11 and later.
    public static let ch34x = DriverGuide(
        steps: [
            "Download the CH34x driver for macOS from WCH, the chip's maker.",
            "Open the download, drag CH34xVCPDriver to Applications, open it, and click Install.",
            "If macOS asks, allow the driver in System Settings > General > Login Items & Extensions > Driver Extensions.",
            "Unplug the panel and plug it back in. This app looks again by itself.",
        ],
        link: URL(string: "https://www.wch-ic.com/downloads/CH34XSER_MAC_ZIP.html")!)
}

/// One section of the app, as the owner reads it.
public struct DeviceSection: Sendable, Equatable {
    public let status: String
    public let detail: String?
    /// A warning the owner must accept before anything else in the section shows or can be used.
    public let warning: String?
    /// How to install the driver, when the device's driver is missing.
    public let guide: DriverGuide?

    init(status: String, detail: String? = nil, warning: String? = nil, guide: DriverGuide? = nil) {
        self.status = status
        self.detail = detail
        self.warning = warning
        self.guide = guide
    }
}

/// The app's two sections (#685).
public struct UpdaterScreen: Sendable, Equatable {
    public let panel: DeviceSection
    public let lc6000: DeviceSection

    /// The LC6000 section's own warning (#685, spec #684 story 9), so someone who owns only a panel never starts on it.
    public static let lc6000Warning = """
        This section changes the firmware inside a Denon LC6000 PRIME. It is not made or supported by Denon. \
        If a change goes wrong, the unit may stop working, and the worst case needs a hardware debug probe to \
        recover. If you only have a deck panel, you don't need this section.
        """

    /// When DeckBridge holds the panel's port (#710's interim, cos): the one sentence, shared with the panel flasher (#687).
    public static let portBusy = "DeckBridge is using the panel's USB cable. Turn off Send over the USB cable in DeckBridge, then look again."

    /// `panelWaiting`: the panel is on USB with no serial port yet, and its driver may still make one (#700).
    /// `deckBridgeSilent`: the port is busy, and DeckBridge didn't let go of it when asked (#710).
    public init(found: Found, lc6000WarningAccepted: Bool, panelWaiting: Bool = false, deckBridgeSilent: Bool = false,
                update: String? = nil, panelUpdate: PanelUpdateOffer? = nil, writing: Bool = false) {
        self.update = update
        cancelNote = writing ? Self.noCancelWhileWriting : nil
        self.panelUpdate = panelUpdate
        firstLookLine = Self.firstLook(found, panelWaiting: panelWaiting)
        switch found.panel {
        case nil: panel = DeviceSection(status: "Nothing connected")
        case .driverMissing where panelWaiting: panel = DeviceSection(status: "Deck panel found", detail: "Waiting for its port")
        case .driverMissing: panel = DeviceSection(status: "Deck panel found", detail: "The USB driver for its chip is missing",
                                                    guide: .ch34x)
        case .onSerial(let build?):
            let development = build.sha.hasSuffix(DeviceFinder.dirty) ? " (a development build)" : ""
            let shown = build.version.map { "Version \($0.description), build \(build.sha)" } ?? "Build \(build.sha)"
            panel = DeviceSection(status: "Deck panel found", detail: shown + development)
        case .portBusy: panel = DeviceSection(status: "Deck panel found", detail: deckBridgeSilent ? Self.deckBridgeNoAnswer : Self.portBusy)
        case .onSerial(nil):
            panel = DeviceSection(status: "Deck panel found",
                            detail: "Build not read")
        }
        guard lc6000WarningAccepted else {
            lc6000 = DeviceSection(status: "Read the warning first", warning: Self.lc6000Warning)
            return
        }
        switch found.lc6000 {
        case nil: lc6000 = DeviceSection(status: "Nothing connected")
        case .onMIDI: lc6000 = DeviceSection(status: "LC6000 found", detail: "Firmware not checked yet")
        case .updateMode: lc6000 = DeviceSection(status: "A device in update mode, maybe an LC6000")
        }
    }

    /// What the update over the cable says now (#687): a step, the result, or what to do; nil before one starts.
    public let update: String?
    /// The update offered for the panel over its cable (#687); nil when there's none.
    public let panelUpdate: PanelUpdateOffer?
    /// Why there's no Cancel: the panel is being written (#744); nil otherwise.
    public let cancelNote: String?

    public static let noCancelWhileWriting =
        "The panel can't be stopped while it's written: it has one app slot, so stopping now would leave it unable to start."

    /// The log's first look (#734): what each section found, in status words only, never a build, serial number or
    /// port, so the launch smoke check can match it exactly. The LC6000's words don't wait for its warning.
    public let firstLookLine: String

    static func firstLook(_ found: Found, panelWaiting: Bool) -> String {
        let panel = switch found.panel {
        case nil: "not found"
        case .driverMissing where panelWaiting: "found (waiting for its port)"
        case .driverMissing: "found (driver missing)"
        case .portBusy: "found (port busy)"
        case .onSerial(let build): build == nil ? "found (build not read)" : "found (build read)"
        }
        let lc6000 = switch found.lc6000 {
        case nil: "not found"
        case .onMIDI: "found"
        case .updateMode: "in update mode"
        }
        return "first look: deck panel \(panel), LC6000 \(lc6000)"
    }
}
