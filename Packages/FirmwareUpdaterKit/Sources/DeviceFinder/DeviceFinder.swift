import Foundation
import FirmwareModel

/// A deck panel the finder saw on USB.
public enum PanelFound: Sendable, Equatable {
    /// On USB, but no driver made a serial port for its chip.
    case driverMissing
    /// On its serial port; the build is nil when its boot line wasn't seen.
    case onSerial(build: PanelBuild?)
}

/// An LC6000 the finder saw. Its firmware isn't read here: nothing is sent to it (#692 checks the unit).
public enum LC6000Found: Sendable, Equatable {
    /// Its MIDI ports are there.
    case onMIDI
    /// ST's ROM bootloader is on USB: any STM32 device in update mode, likely an LC6000's chip.
    case updateMode
}

/// What the finder saw.
public struct Found: Sendable, Equatable {
    public var panel: PanelFound?
    public var lc6000: LC6000Found?

    public init(panel: PanelFound? = nil, lc6000: LC6000Found? = nil) {
        self.panel = panel
        self.lc6000 = lc6000
    }
}

/// Finds a deck panel and an LC6000 (#685). It only looks.
public struct DeviceFinder: Sendable {
    /// The CrowPanel's USB serial chip, a CH340K (tools/deck-panel/README.md).
    static let panelChip = (vendor: UInt16(0x1A86), product: UInt16(0x7522))

    /// The LC6000's MIDI ports carry this in their names, as DeckBridge finds them ("LC6000 PRIME Controller", "… WD").
    static let lc6000Ports = "LC6000 PRIME"
    /// ST's ROM DFU bootloader.
    static let stBootloader = (vendor: UInt16(0x0483), product: UInt16(0xDF11))
    /// The panel's serial speeds, tried in turn: 921600 since #667, then 115200 for a panel flashed before it.
    public static let panelBauds = [921_600, 115_200]

    /// How long the finder listens to a panel's serial port for its boot line, at each speed.
    public static let listenSeconds = 3.0
    static let bootLine = "deck panel: boot, build "
    public static let dirty = "-dirty"

    let usb: any USBDevices
    let midi: any MIDIPorts
    let serial: any PanelSerial
    let log: any LogSink

    public init(usb: any USBDevices, midi: any MIDIPorts, serial: any PanelSerial, log: any LogSink) {
        self.usb = usb
        self.midi = midi
        self.serial = serial
        self.log = log
    }

    /// What is plugged in now. The log gets one line per device found, made only from fixed words, USB ids and the
    /// checked build: never a port path (some drivers name it after the chip's serial number) or a line the panel
    /// printed (it may carry Wi-Fi names, MAC or IP addresses).
    public func find() async -> Found {
        let devices = await usb.devices()
        var found = Found()
        if let chip = devices.first(where: { $0.vendor == Self.panelChip.vendor && $0.product == Self.panelChip.product }) {
            let usbID = Self.hex(chip)
            if let port = chip.serialPort {
                var build: PanelBuild?
                for baud in Self.panelBauds where build == nil {
                    build = Self.build(in: await serial.listen(on: port, baud: baud, for: Self.listenSeconds))
                }
                found.panel = .onSerial(build: build)
                log.log("deck panel: on USB \(usbID), serial port present, " + (build.map { "build \($0.sha)" } ?? "build not read"))
            } else {
                found.panel = .driverMissing
                log.log("deck panel: on USB \(usbID), no serial port (driver missing)")
            }
        }
        if await midi.names().contains(where: { $0.contains(Self.lc6000Ports) }) {
            found.lc6000 = .onMIDI
            log.log("LC6000: MIDI ports present, firmware not checked")
        } else if let st = devices.first(where: { $0.vendor == Self.stBootloader.vendor && $0.product == Self.stBootloader.product }) {
            found.lc6000 = .updateMode
            log.log("LC6000: a device in update mode on USB \(Self.hex(st))")
        }
        return found
    }

    static func hex(_ device: USBDevice) -> String {
        String(format: "%04X:%04X", device.vendor, device.product)
    }

    /// The build from the panel's boot line, "deck panel: boot, build <sha>": a git short SHA, lowercase hex of 7 to
    /// 40 digits, with "-dirty" on a development build (tools/deck-panel/git_sha.py), kept as printed. "unknown" (a
    /// build made outside git) or anything else is no build.
    /// Reads "deck panel: boot, build <sha>" and #695's "deck panel: boot, build <sha>, version <v>[ local]".
    /// A local or development ("-dirty") build gives no version, so its SHA decides.
    static func build(in lines: [String]) -> PanelBuild? {
        for line in lines where line.hasPrefix(bootLine) {
            let tail = line.dropFirst(bootLine.count)
            let parts = tail.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let printed = parts[0]
            let sha = printed.hasSuffix(dirty) ? printed.dropLast(dirty.count) : printed
            guard (7...40).contains(sha.count), sha.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            guard parts.count == 2 else { return PanelBuild(sha: String(printed)) }
            guard let printedVersion = Self.version(in: parts[1]) else { return nil }
            let version = printedVersion.local || printed.hasSuffix(dirty) ? nil : printedVersion.version
            return PanelBuild(sha: String(printed), version: version)
        }
        return nil
    }

    /// " version <dotted digits>" with an optional " local".
    private static func version(in tail: Substring) -> (version: FirmwareVersion, local: Bool)? {
        let prefix = " version ", localSuffix = " local"
        guard tail.hasPrefix(prefix) else { return nil }
        var text = tail.dropFirst(prefix.count)
        let local = text.hasSuffix(localSuffix)
        if local { text = text.dropLast(localSuffix.count) }
        guard text.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }), let version = FirmwareVersion(String(text)) else {
            return nil
        }
        return (version, local)
    }
}
