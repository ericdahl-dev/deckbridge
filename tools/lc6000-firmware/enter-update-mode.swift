// Puts the LC6000 PRIME's jog display chip (wd) into its firmware update mode (#431, #435), the way the stock updater
// does: one SysEx on the unit's "WD" MIDI port. The chip sets a flag and restarts as a USB DFU device (0483:DF11).
// Research tooling for #418. It writes nothing to flash itself, but the unit then stays in update mode until it is
// flashed or power-cycled (whether a power cycle clears the flag is unproven: see the runbook on #431).
//
//   swiftc -O -swift-version 5 enter-update-mode.swift -o /tmp/enter-update-mode
//   /tmp/enter-update-mode selftest                         checks the message and its UMP packing; no MIDI at all
//   /tmp/enter-update-mode check                            lists the WD ports it would use; sends nothing
//   /tmp/enter-update-mode send --yes-enter-update-mode     sends the message, once, to the one WD port
//
// It only ever sends this one message, only to a port whose name contains "LC6000 PRIME WD", and refuses when there
// isn't exactly one such port. The top panel chip (tp) has no need of it: hold BACK + FWD + VINYL at power-on.
import CoreMIDI
import Foundation

/// F0 00 02 0B 01 10 72 00 00 F7: inMusic's "enter update mode" (the stock updater's GetPutIntoUpdateModeSysexMessage).
let message: [UInt8] = [0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x72, 0x00, 0x00, 0xF7]
let portHint = "LC6000 PRIME WD"

/// A complete SysEx as UMP SysEx7 packets (MIDI 1.0 protocol): two words each, up to six data bytes, without F0/F7.
func sysex7(_ bytes: [UInt8]) -> [[UInt32]] {
    precondition(bytes.first == 0xF0 && bytes.last == 0xF7)
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

func destinations() -> [(ref: MIDIEndpointRef, name: String)] {
    (0..<MIDIGetNumberOfDestinations()).compactMap { index in
        let ref = MIDIGetDestination(index)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
        guard let text = name?.takeRetainedValue() as String?, text.contains(portHint) else { return nil }
        return (ref, text)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "selftest":
    let checks: [(String, Bool)] = [
        ("the message is 10 bytes, F0 … F7", message.count == 10 && message.first == 0xF0 && message.last == 0xF7),
        ("two packets: start with 6 bytes, end with 2", sysex7(message) == [[0x3016_0002, 0x0B01_1072], [0x3032_0000, 0x0000_0000]]),
        ("a short SysEx is one complete packet", sysex7([0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]) == [[0x3004_7E00, 0x0601_0000]]),
    ]
    for (name, passed) in checks where !passed { print("FAIL: \(name)"); exit(1) }
    print("selftest ok")
case "check":
    let found = destinations()
    for port in found { print("WD port: \(port.name)") }
    if found.count != 1 { print("refused: \(found.count) ports named \"\(portHint)\"; exactly one is needed"); exit(1) }
    print("ok: one WD port. Nothing was sent.")
case "send" where arguments.dropFirst().first == "--yes-enter-update-mode":
    let found = destinations()
    guard found.count == 1, let port = found.first else {
        print("refused: \(found.count) ports named \"\(portHint)\"; exactly one is needed. Nothing was sent.")
        exit(1)
    }
    var client = MIDIClientRef(), out = MIDIPortRef()
    guard MIDIClientCreateWithBlock("lc6000-enter-update-mode" as CFString, &client, nil) == noErr,
          MIDIOutputPortCreate(client, "out" as CFString, &out) == noErr else { print("refused: couldn't open CoreMIDI"); exit(1) }
    var list = MIDIEventList()
    var packet = MIDIEventListInit(&list, ._1_0)
    for words in sysex7(message) { packet = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, words.count, words) }
    let status = MIDISendEventList(out, port.ref, &list)
    guard status == noErr else { print("refused: the send failed (\(status))"); exit(1) }
    // Give CoreMIDI a moment to hand the packets to the driver before the process ends.
    usleep(300_000)
    print("sent to \(port.name): " + message.map { String(format: "%02X", $0) }.joined(separator: " "))
default:
    print("usage: selftest | check | send --yes-enter-update-mode")
    exit(2)
}
