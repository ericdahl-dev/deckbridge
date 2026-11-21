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
        for words in SysEx7.packets(bytes) {
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
}
