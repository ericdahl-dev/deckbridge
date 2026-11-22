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
    /// Ports another app holds exclusively (DeckBridge, TIOCEXCL): opening them fails busy.
    var busy: Set<String> = []
    /// What a #702 panel answers at 921600 (after #711) or 115200 (today's firmware) when asked "version\n" (#715);
    /// nothing unless asked.
    var answers: [String: [String]] = [:]
    var oldAnswers: [String: [String]] = [:]
    /// Everything written to any port, in order: the test checks it is only ever the version question, on the panel's.
    struct Write: Equatable {
        let port: String
        let baud: Int
        let text: String
    }
    var writes: [Write] = []
    /// The panel console's line buffer (owner run, #726): bytes written at the wrong speed land there as junk, so the
    /// next line it reads is "<junk>version" and isn't the question, unless that line starts with a newline.
    private var junk: Set<String> = []

    /// Whether the panel, talking at `baud`, reads `text` as the question "version".
    private func heardQuestion(_ text: String, on port: String, at baud: Int) -> Bool {
        let speed = oldAnswers[port] != nil ? 115_200 : answers[port] != nil ? 921_600 : nil
        guard let speed else { return false }
        guard baud == speed else {
            junk.insert(port)
            return false
        }
        let buffered = (junk.remove(port) != nil ? "\u{FFFD}" : "") + text
        return buffered.split(separator: "\n", omittingEmptySubsequences: false).dropLast().contains("version")
    }
    func listen(on port: String, baud: Int, for seconds: Double, asking question: String?) async -> Listened {
        opened.append(port)
        bauds.append(baud)
        if busy.contains(port) { return .busy }
        if let question { writes.append(Write(port: port, baud: baud, text: question)) }
        let asked = question.map { heardQuestion($0, on: port, at: baud) } ?? false
        switch baud {
        case 921_600: return .lines((lines[port] ?? []) + (asked ? answers[port] ?? [] : []))
        case 115_200: return .lines((oldLines[port] ?? []) + (asked ? oldAnswers[port] ?? [] : []))
        default: return .lines([])
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
