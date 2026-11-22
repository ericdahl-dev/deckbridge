#if DEBUG
import DeviceFinder
import FirmwareModel
import PanelFlasher

/// The screenshot preview (#761), Debug builds only: the window in a fixed state, on fake ports. Every port here is a
/// plain value in this file: this package has no IOKit, CoreMIDI or serial code, and the preview has no DeckBridge
/// handoff, so nothing is opened, sent or signaled.
public enum PreviewState: String, CaseIterable, Sendable {
    /// Nothing plugged in.
    case nothing
    /// The panel on its cable with its build read, an update offered, and an LC6000 on MIDI.
    case found
    /// As `found`, with an update over the cable stopped on its writing step.
    case updating
}

extension Updater {
    /// A model for `state` on fake ports, with a fixed firmware line and no handoff.
    public static func preview(_ state: PreviewState) -> Updater {
        let plugged = state != .nothing
        let finder = DeviceFinder(usb: PreviewUSB(plugged: plugged), midi: PreviewMIDI(plugged: plugged),
                                  serial: PreviewSerial(), log: PreviewLog())
        let model = Updater(finder: finder, changes: AsyncStream { $0.finish() },
                            firmware: { FirmwareLine(source: "Firmware 1.4.0, from this project's newest release", reason: nil) },
                            flasher: PreviewFlasher())
        if plugged { model.acceptLC6000Warning() }
        return model
    }
}

private struct PreviewUSB: USBDevices {
    let plugged: Bool
    func devices() async -> [USBDevice] {
        plugged ? [USBDevice(vendor: 0x1A86, product: 0x7522, name: "USB Serial", serialPort: PreviewSerial.port)] : []
    }
}

private struct PreviewMIDI: MIDIPorts {
    let plugged: Bool
    func names() async -> [String] { plugged ? ["LC6000 PRIME Controller"] : [] }
}

private struct PreviewSerial: PanelSerial {
    /// A made-up name: never opened, only matched against the fake USB device's.
    static let port = "/dev/cu.preview"
    func listen(on port: String, baud: Int, for seconds: Double, asking question: String?) async -> Listened {
        .lines(["deck panel: boot, build 0123abc, version 1.3.0"])
    }
}

private struct PreviewLog: LogSink {
    func log(_ line: String) {}
}

/// Offers 1.4.0 to any build; an update stops on 42 % written and stays there.
private struct PreviewFlasher: PanelFlashing {
    func offer(for build: PanelBuild) -> PanelUpdateOffer? { PanelUpdateOffer(version: "1.4.0", note: nil) }
    func repairVersion() -> String? { "1.4.0" }
    func flash(report: @escaping @Sendable (PanelUpdate.Step) -> Void) async {
        report(.connecting)
        report(.writing(0.42))
        try? await Task.sleep(for: .seconds(86_400))
    }
}
#endif
