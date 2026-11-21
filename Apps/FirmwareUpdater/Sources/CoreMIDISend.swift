import CoreMIDI
import Foundation
import UnitCheck

/// The update-mode step's one send (#692), as tools/lc6000-firmware/enter-update-mode.swift sends it: a SysEx as UMP
/// SysEx7 packets on a CoreMIDI output port. Used only by UpdateModeStep, after the owner typed UPDATE.
struct CoreMIDISend: MIDISend {
    func destinations() async -> [String] { Self.named().map(\.name) }

    func send(_ bytes: [UInt8], to port: String) async -> Bool {
        guard let destination = Self.named().first(where: { $0.name == port })?.ref else { return false }
        var client = MIDIClientRef(), out = MIDIPortRef()
        guard MIDIClientCreateWithBlock("FirmwareUpdater" as CFString, &client, nil) == noErr,
              MIDIOutputPortCreate(client, "out" as CFString, &out) == noErr else { return false }
        defer { MIDIClientDispose(client) }
        var list = MIDIEventList()
        var packet = MIDIEventListInit(&list, ._1_0)
        for words in Self.sysex7(bytes) {
            packet = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, words.count, words)
        }
        guard MIDISendEventList(out, destination, &list) == noErr else { return false }
        try? await Task.sleep(for: .milliseconds(300)) // the send leaves before the client goes
        return true
    }

    private static func named() -> [(ref: MIDIEndpointRef, name: String)] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let ref = MIDIGetDestination(index)
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name) == noErr,
                  let text = name?.takeRetainedValue() as String? else { return nil }
            return (ref, text)
        }
    }

    /// The kit's packing: two words a packet, up to six data bytes, without F0/F7.
    static func sysex7(_ bytes: [UInt8]) -> [[UInt32]] {
        let data = Array(bytes.dropFirst().dropLast())
        let chunks = stride(from: 0, to: max(data.count, 1), by: 6).map { Array(data[$0..<min($0 + 6, data.count)]) }
        return chunks.enumerated().map { index, chunk in
            let status: UInt32 = chunks.count == 1 ? 0 : index == 0 ? 1 : index == chunks.count - 1 ? 3 : 2
            var padded = chunk.map(UInt32.init)
            padded += Array(repeating: 0, count: 6 - padded.count)
            return [0x3000_0000 | status << 20 | UInt32(chunk.count) << 16 | padded[0] << 8 | padded[1],
                    padded[2] << 24 | padded[3] << 16 | padded[4] << 8 | padded[5]]
        }
    }
}
