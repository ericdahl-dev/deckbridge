// The LC6000 jog display's ports in CoreMIDI (#165). Not unit-tested: the driver and Coordinator are tested in the
// Kit through JogDisplayPort; the hardware check covers this. SysEx goes out as UMP SysEx7 at USB speed, as djay sends
// it (#168); the WD port's answers are reassembled and go into the pipe, in order with everything else.
import CoreMIDI
import Foundation
import os
import ControllerBridgeCore
import Synchronization

/// Sends to the unit's WD port and its Controller port, found by name and remembered until CoreMIDI's setup changes, so
/// a replug just works; listens to
/// the WD port for the unit's upload answers. Nothing is sent unless the Coordinator's switch is on.
final class CoreMIDIJogDisplay: JogDisplayPort {
    /// The unit's two ports, as CoreMIDI names them: "… LC6000 PRIME WD" and "… LC6000 PRIME Controller".
    static let wdHint = "LC6000 PRIME WD"
    static let controllerHint = "LC6000 PRIME Controller"

    private let output: MIDIPortRef
    private let input: MIDIPortRef
    // Sends are made where they're called: on the MIDISendQueue's worker (#552), never the Engine's loop. A queue of
    // its own here hid a wedged WD port from the send queue's stuck check and piled its SysEx up unbounded (#595).
    private static let logger = Logger(subsystem: "dev.ericdahl.ControllerBridge", category: "jog-display")
    /// A send slower than this is logged: what a stall looks like from here.
    private static let slowSend: Double = 0.1
    private let listening = Mutex<MIDIUniqueID?>(nil)
    /// The ports found by name, or found missing, until CoreMIDI's setup changes (#552): `isAttached` runs on the
    /// Engine's loop on every tick, and each lookup is a round-trip to the MIDI server per endpoint.
    private let found = Mutex<[String: MIDIEndpointRef?]>([:])

    /// CoreMIDI's setup changed (a device came or went): the next lookup reads the ports again.
    func forgetEndpoints() {
        found.withLock { $0.removeAll() }
    }

    /// `find`, remembered until `forgetEndpoints`.
    private func cachedFind(sources: Bool, hint: String) -> MIDIEndpointRef? {
        let key = (sources ? "source " : "destination ") + hint
        if let known = found.withLock({ $0[key] }) { return known }
        let ref = Self.find(sources: sources, hint: hint)
        found.withLock { $0[key] = .some(ref) }
        return ref
    }

    /// Makes the ports on the app's MIDI client. Must run on the main thread, as the client was.
    @MainActor
    init(client: MIDIClientRef, producer: EventPipe.Producer) throws {
        var output = MIDIPortRef()
        try check("MIDIOutputPortCreate", MIDIOutputPortCreate(client, "Jog display out" as CFString, &output))
        var input = MIDIPortRef()
        try check("MIDIInputPortCreateWithProtocol", MIDIInputPortCreateWithProtocol(
            client, "Jog display in" as CFString, ._1_0, &input, Self.receiveBlock(SysExAssembler(producer))
        ))
        self.output = output
        self.input = input
    }

    /// Connects the WD source, when it's there and not yet connected: before each WD send, so the answers to it are
    /// heard, after a replug too.
    private func listen() {
        guard let source = cachedFind(sources: true, hint: Self.wdHint) else { return }
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id)
        let isNew = listening.withLock { current in
            defer { current = id }
            return current != id
        }
        if isNew { MIDIPortConnectSource(input, source, nil) }
    }

    /// The WD port is there now (#305): without it, nothing is sent and no upload is waited on.
    var isAttached: Bool { cachedFind(sources: false, hint: Self.wdHint) != nil }

    func sendController(_ bytes: [UInt8]) {
        send(bytes, hint: Self.controllerHint)
    }

    func sendWD(_ bytes: [UInt8]) {
        listen()
        send(bytes, hint: Self.wdHint)
    }

    private func send(_ bytes: [UInt8], hint: String) {
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let took = ProcessInfo.processInfo.systemUptime - started
            if took >= Self.slowSend {
                Self.logger.error("Slow send to \(hint, privacy: .public): \(bytes.count) bytes took \(Int(took * 1000)) ms")
            }
        }
        guard let destination = cachedFind(sources: false, hint: hint) else { return }
        let words: [[UInt32]] = bytes.first == 0xF0 ? UMP.sysex7(bytes) : [[UMP.voice(bytes)]]
        // At most 512 packets a list, about 4 KB of SysEx: big enough to be fast, small enough for any buffer.
        let capacity = 1024 * 4 * 8 + 1024
        let list = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8).bindMemory(to: MIDIEventList.self, capacity: 1)
        defer { list.deallocate() }
        for start in stride(from: 0, to: words.count, by: 512) {
            var packet = MIDIEventListInit(list, ._1_0)
            for packetWords in words[start..<min(start + 512, words.count)] {
                packet = MIDIEventListAdd(list, capacity, packet, 0, packetWords.count, packetWords)
            }
            MIDISendEventList(output, destination, list)
        }
    }

    private static func find(sources: Bool, hint: String) -> MIDIEndpointRef? {
        let count = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        for index in 0..<count {
            let ref = sources ? MIDIGetSource(index) : MIDIGetDestination(index)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
            if let text = name?.takeRetainedValue() as String?, text.contains(hint) { return ref }
        }
        return nil
    }

    private nonisolated static func receiveBlock(_ assembler: SysExAssembler) -> MIDIReceiveBlock {
        { list, _ in
            for packet in list.unsafeSequence() { assembler.feed(Array(packet.words())) }
        }
    }
}

/// Hands each whole SysEx the WD port sends to the pipe. The packet math is the Kit's SysExReassembler (#309).
final class SysExAssembler: Sendable {
    private let producer: EventPipe.Producer
    private let reassembler = Mutex(SysExReassembler())

    init(_ producer: EventPipe.Producer) { self.producer = producer }

    func feed(_ words: [UInt32]) {
        for message in reassembler.withLock({ $0.feed(words) }) { producer.jogDisplayReply(message) }
    }
}

private func check(_ call: String, _ status: OSStatus) throws {
    guard status == noErr else { throw CoreMIDIError.status(call, status) }
}
