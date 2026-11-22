// The capture window's MIDI input (#186). Not unit-tested: the words-to-bytes conversion is in the Kit
// (CaptureMIDI), and the live path is on the manual checklist.
import CoreMIDI
import ControllerBridgeCapture
import ControllerBridgeCore
import Foundation

/// Listens to the ports being captured, on its own CoreMIDI client. It has an input port and no output port, so it
/// can't send anything to the controller. Each message is handed on with the port's index and the host time.
final class CaptureMIDIInput {
    private var client = MIDIClientRef()
    private var input = MIDIPortRef()
    private let sources: [MIDIEndpoint]

    /// `receive` gets each message's bytes, the time (system uptime, seconds) and the port's index in `sources`.
    /// Called on CoreMIDI's thread. `changed` is called when the system's MIDI devices may have changed (#229), on the
    /// thread that made this input: make it on the main thread.
    init?(
        sources: [MIDIEndpoint], receive: @escaping @Sendable ([UInt8], Double, Int) -> Void,
        changed: @escaping @Sendable () -> Void = {}
    ) {
        self.sources = sources
        guard MIDIClientCreateWithBlock("ControllerBridge capture" as CFString, &client, Self.notifyBlock(changed)) == noErr,
            MIDIInputPortCreateWithProtocol(client, "Capture in" as CFString, ._1_0, &input, Self.receiveBlock(receive)) == noErr
        else { return nil }
        connect()
    }

    /// Connects every source that's there, again after a replug: an endpoint keeps its unique id across one.
    func connect() {
        for (index, source) in sources.enumerated() {
            guard let ref = Self.find(source) else { continue }
            // The port's index rides along as the refCon, plus one so index 0 isn't a null pointer.
            MIDIPortConnectSource(input, ref, UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    /// The unique ids of the sources CoreMIDI lists now, leaving out any marked offline (#315): an unplugged USB
    /// device's endpoint can still be found by its id.
    static func onlineSourceIDs() -> [Int32] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let ref = MIDIGetSource(index)
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(ref, kMIDIPropertyOffline, &offline)
            guard offline == 0 else { return nil }
            var id: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &id)
            return id
        }
    }

    private nonisolated static func notifyBlock(_ changed: @escaping @Sendable () -> Void) -> MIDINotifyBlock {
        { notification in
            switch notification.pointee.messageID {
            case .msgObjectAdded, .msgObjectRemoved, .msgSetupChanged: changed()
            default: break
            }
        }
    }

    /// Stops listening. Nothing arrives after this.
    func stop() {
        MIDIPortDispose(input)
        MIDIClientDispose(client)
    }

    private nonisolated static func receiveBlock(_ receive: @escaping @Sendable ([UInt8], Double, Int) -> Void) -> MIDIReceiveBlock {
        { list, refCon in
            let now = ProcessInfo.processInfo.systemUptime
            let port = Int(bitPattern: refCon) - 1
            for packet in list.unsafeSequence() {
                for bytes in CaptureMIDI.bytes(words: Array(packet.words())) { receive(bytes, now, port) }
            }
        }
    }

    private static func find(_ endpoint: MIDIEndpoint) -> MIDIEndpointRef? {
        var object = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(endpoint.id, &object, &type) == noErr, object != 0 else { return nil }
        return object
    }
}
