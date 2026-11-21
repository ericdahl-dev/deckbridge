import DeviceFinder
import Foundation
import UpdaterScreen

/// Fake ports: what the test plugs in. Each records what it was asked.
final class FakeUSB: USBDevices, @unchecked Sendable {
    var plugged: [USBDevice] = []
    func devices() async -> [USBDevice] { plugged }
}

final class FakeMIDI: MIDIPorts, @unchecked Sendable {
    var ports: [String] = []
    func names() async -> [String] { ports }
}

final class FakeSerial: PanelSerial, @unchecked Sendable {
    /// What the panel prints on each port while the app listens at 921600, the speed since #667.
    var lines: [String: [String]] = [:]
    /// What a panel flashed before #667 prints, at 115200.
    var oldLines: [String: [String]] = [:]
    /// Every port the finder opened, and at which speed.
    var opened: [String] = []
    var bauds: [Int] = []
    func listen(on port: String, baud: Int, for seconds: Double) async -> [String] {
        opened.append(port)
        bauds.append(baud)
        switch baud {
        case 921_600: return lines[port] ?? []
        case 115_200: return oldLines[port] ?? []
        default: return []
        }
    }
}

final class FakeLog: LogSink, @unchecked Sendable {
    let lock = NSLock()
    var lines: [String] = []
    func log(_ line: String) { lock.withLock { lines.append(line) } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

struct Rig {
    let usb = FakeUSB()
    let midi = FakeMIDI()
    let serial = FakeSerial()
    let log = FakeLog()

    var finder: DeviceFinder { DeviceFinder(usb: usb, midi: midi, serial: serial, log: log) }

    func screen(lc6000WarningAccepted: Bool = true) async -> UpdaterScreen {
        UpdaterScreen(found: await finder.find(), lc6000WarningAccepted: lc6000WarningAccepted)
    }
}
