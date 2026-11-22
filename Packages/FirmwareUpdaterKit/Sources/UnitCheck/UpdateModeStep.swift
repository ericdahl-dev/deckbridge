/// MIDI destinations by name, and a send to one. The app's adapter is CoreMIDI.
public protocol MIDISend: Sendable {
    func destinations() async -> [String]
    /// False when the send failed.
    func send(_ bytes: [UInt8], to port: String) async -> Bool
}

/// The display chip's step into update mode (#692): one message on its WD port, only when the owner typed UPDATE.
/// A port of tools/lc6000-firmware/enter-update-mode.swift. It writes nothing to flash, but the chip stays in update
/// mode until it is flashed or power-cycled.
public struct UpdateModeStep: Sendable {
    /// What the screen says once the step is sent. A power cycle ends update mode: the owner saw it (2026-11-22).
    public static let sentText = "Sent. The display chip restarts in update mode: give it a few seconds, then back it up. "
        + "A power cycle ends update mode, and the chip starts its own firmware again."

    public enum Outcome: Sendable, Hashable {
        case sent
        case refused(String)
    }

    let midi: any MIDISend
    let apps: any RunningApps

    public init(midi: any MIDISend, apps: any RunningApps) {
        self.midi = midi
        self.apps = apps
    }

    /// inMusic's "enter update mode", as the kit sends it (enter-update-mode.swift).
    static let message: [UInt8] = [0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x72, 0x00, 0x00, 0xF7]
    static let portHint = "LC6000 PRIME WD"

    /// Sends the message once, or nothing. Never retried.
    public func enter(typed: String) async -> Outcome {
        guard typed == "UPDATE" else { return .refused("You didn't type UPDATE, so nothing was sent.") }
        if let stop = await Preflight(apps: apps).stop() { return .refused(stop) }
        let ports = await midi.destinations().filter { $0.contains(Self.portHint) }
        guard let port = ports.first else {
            return .refused("The LC6000's display port isn't there. Is the LC6000 on, on a direct cable? Nothing was sent.")
        }
        guard ports.count == 1 else {
            return .refused("There are two LC6000 display ports. Connect one LC6000 only. Nothing was sent.")
        }
        guard await midi.send(Self.message, to: port) else { return .refused("The message couldn't be sent.") }
        return .sent
    }
}

/// A complete SysEx as UMP SysEx7 packets (MIDI 1.0 protocol): two words each, up to six data bytes, without F0/F7.
/// The kit's packing (enter-update-mode.swift), for the app's CoreMIDI send.
public enum SysEx7 {
    public static func packets(_ bytes: [UInt8]) -> [[UInt32]] {
        let data = Array(bytes.dropFirst().dropLast())
        let chunks = stride(from: 0, to: max(data.count, 1), by: 6).map { Array(data[$0..<min($0 + 6, data.count)]) }
        return chunks.enumerated().map { index, chunk in
            // 0 complete, 1 start, 2 continue, 3 end.
            let status: UInt32 = chunks.count == 1 ? 0 : index == 0 ? 1 : index == chunks.count - 1 ? 3 : 2
            var padded = chunk.map(UInt32.init)
            padded += Array(repeating: 0, count: 6 - padded.count)
            return [0x3000_0000 | status << 20 | UInt32(chunk.count) << 16 | padded[0] << 8 | padded[1],
                    padded[2] << 24 | padded[3] << 16 | padded[4] << 8 | padded[5]]
        }
    }
}
