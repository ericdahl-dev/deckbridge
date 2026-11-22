import Foundation

/// What the Diagnostics window shows (#26): MIDI in, OSC out and in, and the LED sweep's steps. The Coordinator only
/// builds one while a sink is set (`Coordinator.diagnostics`), so a set without the window open formats nothing.
public enum DiagnosticEvent: Equatable, Sendable {
    /// A message from the controller, with its mapping name or "UNMAPPED", and when it arrived (monotonic seconds).
    case midiIn(MIDIEvent, label: String, at: Double)
    /// OSC sent to Syndicate.
    case oscOut(OSCMessage)
    /// OSC feedback from Syndicate.
    case oscIn(OSCMessage)
    /// A line from the LED sweep, as the Python led-sweep printed it.
    case sweep(String)

    /// The line as the Python bridge printed it, so a hardware check reads the same.
    public var text: String {
        switch self {
        case .midiIn(let event, let label, let time):
            // lc6000_bridge/cli.py (removed in #30): f"{time.monotonic():12.3f}  ch{ch:<2} {str(msg):<50} {label}"
            let channel = String(event.channel + 1).padding(toLength: 2, withPad: " ", startingAt: 0)
            let message = event.midoText.padding(toLength: max(50, event.midoText.count), withPad: " ", startingAt: 0)
            return String(format: "%12.3f", time) + "  ch" + channel + " " + message + " " + label
        // lc6000_bridge/cli.py (removed in #30) --verbose: print("OSC ->", address, *args)
        case .oscOut(let message): return (["OSC ->", message.address] + message.arguments.map(\.pythonText)).joined(separator: " ")
        case .oscIn(let message): return (["OSC <-", message.address] + message.arguments.map(\.pythonText)).joined(separator: " ")
        case .sweep(let line): return line
        }
    }
}

extension DiagnosticEvent {
    /// The line in two parts, so the window can color the mapping label: `message + label == text`.
    public struct LineParts: Equatable, Sendable {
        public var message: String
        /// The mapping name or "UNMAPPED" for a monitor line; empty for every other line.
        public var label: String
        public var isUnmapped: Bool { label == DiagnosticEvent.unmapped }
    }

    /// The monitor's label for a message the mapping doesn't name.
    public static let unmapped = "UNMAPPED"

    public var lineParts: LineParts {
        let line = text
        guard case .midiIn(_, let label, _) = self, line.hasSuffix(label) else { return LineParts(message: line, label: "") }
        return LineParts(message: String(line.dropLast(label.count)), label: label)
    }
}

extension MIDIEvent {
    var channel: UInt8 {
        switch self {
        case .noteOn(let channel, _, _), .noteOff(let channel, _, _), .controlChange(let channel, _, _): channel
        }
    }

    /// The message as the Python mido library prints it.
    var midoText: String {
        switch self {
        case .noteOn(let channel, let note, let velocity): "note_on channel=\(channel) note=\(note) velocity=\(velocity) time=0"
        case .noteOff(let channel, let note, let velocity): "note_off channel=\(channel) note=\(note) velocity=\(velocity) time=0"
        case .controlChange(let channel, let controller, let value): "control_change channel=\(channel) control=\(controller) value=\(value) time=0"
        }
    }
}

extension Mapping {
    /// A pad or ring LED's name for the trace (#530): "ring", "pad1"…, or the note.
    func ledName(note: Int) -> String {
        if note == leds.ring { return "ring" }
        if let index = notes.pads.firstIndex(of: note) { return "pad\(index + 1)" }
        return "note \(note)"
    }

    /// The mapping name of a message, as the Python monitor printed it: a button name, "pad1"…"pad8", a CC name, or
    /// "UNMAPPED". Any channel.
    func monitorName(for event: MIDIEvent) -> String {
        switch event {
        case .noteOn(_, let note, _), .noteOff(_, let note, _):
            let note = Int(note)
            if let pad = notes.pads.firstIndex(of: note) { return "pad\(pad + 1)" }
            return notes.buttons.first { $0.value == note }?.key ?? DiagnosticEvent.unmapped
        case .controlChange(_, let controller, _):
            let cc = Int(controller)
            let jogNames: [(Int, String)] = switch jog?.mode {
            case .absolute(let msb, let lsb): [(msb, "jog_msb"), (lsb, "jog_lsb")]
            case .relative(let cc, let edge): [(cc, "jog_relative")] + (edge.map { [($0, "jog_relative_edge")] } ?? [])
            case nil: []
            }
            let named: [(Int, String)] = jogNames
              + (pitch.map { [($0.msbCC, "pitch_msb"), ($0.bits == 14 ? $0.lsbCC ?? -1 : -1, "pitch_lsb")] } ?? [])
              + (browse.map { [($0.selectTurnCC, "select_turn"), ($0.autoLoopSizeCC, "auto_loop_size")] } ?? [])
              + (needle.map { [($0.msbCC, "needle_msb"), ($0.lsbCC, "needle_lsb")] } ?? [])
            return named.first { $0.0 == cc }?.1 ?? DiagnosticEvent.unmapped
        }
    }
}

extension OSCArgument {
    /// As Python prints the decoded value: an int, a float as its shortest round-trip repr ("0.25", "128.0"), a string.
    var pythonText: String {
        switch self {
        case .int(let value): String(value)
        case .float(let value): String(Double(value))
        case .string(let value): value
        }
    }
}

/// Passes OSC on to the real sender, and to the OSC log while Diagnostics is open.
final class OSCTap: OSCSender, @unchecked Sendable {
    private let inner: any OSCSender
    /// Set and read only on the Coordinator's one consumer.
    var onSend: ((OSCMessage) -> Void)?
    /// The debug trace's view of what's sent (#395), whether or not Diagnostics is open.
    var onTrace: ((OSCMessage) -> Void)?

    init(_ inner: any OSCSender) { self.inner = inner }

    func send(_ message: OSCMessage) {
        inner.send(message)
        onSend?(message)
        onTrace?(message)
    }
}
