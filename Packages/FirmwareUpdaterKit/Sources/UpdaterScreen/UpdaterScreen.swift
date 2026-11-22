import DeviceFinder

/// One section of the app, as the owner reads it.
public struct DeviceSection: Sendable, Equatable {
    public let status: String
    public let detail: String?
    /// A warning the owner must accept before anything else in the section shows or can be used.
    public let warning: String?

    init(status: String, detail: String? = nil, warning: String? = nil) {
        self.status = status
        self.detail = detail
        self.warning = warning
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

    public init(found: Found, lc6000WarningAccepted: Bool) {
        switch found.panel {
        case nil: panel = DeviceSection(status: "Nothing connected")
        case .driverMissing: panel = DeviceSection(status: "Deck panel found", detail: "The USB driver for its chip is missing")
        case .onSerial(let build?):
            let development = build.sha.hasSuffix(DeviceFinder.dirty) ? " (a development build)" : ""
            let shown = build.version.map { "Version \($0.description), build \(build.sha)" } ?? "Build \(build.sha)"
            panel = DeviceSection(status: "Deck panel found", detail: shown + development)
        case .portBusy: panel = DeviceSection(status: "Deck panel found", detail: Self.portBusy)
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
}
