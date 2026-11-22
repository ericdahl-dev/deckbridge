// The CoreMIDI adapter. Not unit-tested: the smoke script (scripts/smoke.sh) covers it.
import CoreMIDI
import ControllerBridgeCore
import Synchronization

enum CoreMIDIError: Error {
    case status(String, OSStatus)
    case endpointGone(MIDIEndpoint)
}

/// Lists, connects and sends through CoreMIDI. Incoming MIDI is parsed inside the realtime callback and goes into the
/// EventPipe; nothing else happens on that thread.
///
/// Every CoreMIDI block is made in a `nonisolated static` function: a closure written in main-actor code would be
/// main-actor isolated, and CoreMIDI blocks get no runtime isolation check, so it would race silently (#14 spike).
final class CoreMIDISystem: MIDISystem {
    /// The app's one MIDI client; the jog display's ports are made on it too (#165).
    let client: MIDIClientRef
    private let input: MIDIPortRef
    private let output: MIDIPortRef
    /// Connected sources by unique id, with their names.
    private let connected = Mutex<[MIDIUniqueID: String]>([:])
    private let relay: ChangeRelay
    private let onChange: @Sendable ([String]) -> Void

    /// Calls `onChange` with the names of the connected sources whenever that list may have changed.
    /// Must run on the main thread: notifications arrive on the run loop of the thread that made the client.
    @MainActor
    init(producer: EventPipe.Producer, onChange: @escaping @Sendable ([String]) -> Void) throws {
        let relay = ChangeRelay()
        var client = MIDIClientRef()
        try check("MIDIClientCreateWithBlock", MIDIClientCreateWithBlock("ControllerBridge" as CFString, &client, Self.notifyBlock(relay)))
        var input = MIDIPortRef()
        try check("MIDIInputPortCreateWithProtocol",
                  MIDIInputPortCreateWithProtocol(client, "Controller in" as CFString, ._1_0, &input, Self.receiveBlock(producer)))
        var output = MIDIPortRef()
        try check("MIDIOutputPortCreate", MIDIOutputPortCreate(client, "LED out" as CFString, &output))
        self.client = client
        self.input = input
        self.output = output
        self.relay = relay
        self.onChange = onChange
        // A device came or went: refresh the names, and let the Coordinator re-read the devices (#20). Through the pipe,
        // so it stays in order behind the MIDI already queued from that device.
        // What was removed rides along (#429): a unit power-cycled quickly is back before the Coordinator looks.
        relay.set { [weak self] removed in
            self?.pruneRemovedSources()
            producer.devicesChanged(removed: removed)
        }
    }

    /// Calls `observer` on every change to CoreMIDI's setup, before the Coordinator hears of it.
    func observeChanges(_ observer: @escaping @Sendable () -> Void) { relay.observe(observer) }

    var sources: [MIDIEndpoint] { (0..<MIDIGetNumberOfSources()).map { relay.remember(MIDIGetSource($0)) } }
    var destinations: [MIDIEndpoint] { (0..<MIDIGetNumberOfDestinations()).map { relay.remember(MIDIGetDestination($0)) } }

    func connect(source: MIDIEndpoint) throws {
        let ref = try ref(source)
        // The unique id rides along as the connection refCon, so each event knows its source.
        try check("MIDIPortConnectSource", MIDIPortConnectSource(input, ref, UnsafeMutableRawPointer(bitPattern: Int(source.id))))
        let names = connected.withLock { $0[source.id] = source.name; return Array($0.values) }
        onChange(names)
    }

    func disconnect(source: MIDIEndpoint) {
        if let ref = try? ref(source) { MIDIPortDisconnectSource(input, ref) }
        let names = connected.withLock { $0[source.id] = nil; return Array($0.values) }
        onChange(names)
    }

    func openOutput(destination: MIDIEndpoint) throws -> any MIDIOutput {
        CoreMIDIOutput(port: output, destination: try ref(destination))
    }

    private func pruneRemovedSources() {
        let names = connected.withLock { sources in
            sources = sources.filter { id, _ in (try? Self.find(MIDIEndpoint(id: id, name: ""))) != nil }
            return Array(sources.values)
        }
        onChange(names)
    }

    // MARK: Blocks, made outside any actor

    private nonisolated static func receiveBlock(_ producer: EventPipe.Producer) -> MIDIReceiveBlock {
        { list, refCon in
            let source = MIDIEndpoint.ID(truncatingIfNeeded: Int(bitPattern: refCon))
            for packet in list.unsafeSequence() {
                for event in MIDIParse.events(words: Array(packet.words())) { producer.midi(event, source: source) }
            }
        }
    }

    private nonisolated static func notifyBlock(_ relay: ChangeRelay) -> MIDINotifyBlock {
        { notification in
            switch notification.pointee.messageID {
            case .msgObjectRemoved:
                let child = UnsafeRawPointer(notification).assumingMemoryBound(to: MIDIObjectAddRemoveNotification.self).pointee.child
                relay.removed(child)
                relay.fire()
            case .msgObjectAdded, .msgSetupChanged: relay.fire()
            default: break
            }
        }
    }

    // MARK: Endpoints

    private static func endpoint(_ ref: MIDIEndpointRef) -> MIDIEndpoint {
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &id)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
        return MIDIEndpoint(id: id, name: (name?.takeRetainedValue() as String?) ?? "MIDI \(id)")
    }

    /// The endpoint's ref as last listed (#595), so connecting and opening on the engine's loop don't look it up in
    /// CoreMIDI; one never listed is looked up.
    private func ref(_ endpoint: MIDIEndpoint) throws -> MIDIEndpointRef {
        if let known = relay.ref(for: endpoint.id) { return known }
        return try Self.find(endpoint)
    }

    private static func find(_ endpoint: MIDIEndpoint) throws -> MIDIEndpointRef {
        var object = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(endpoint.id, &object, &type) == noErr, object != 0 else {
            throw CoreMIDIError.endpointGone(endpoint)
        }
        return object
    }
}

/// Sends to one destination. CoreMIDI sends are thread-safe.
struct CoreMIDIOutput: MIDIOutput {
    let port: MIDIPortRef
    let destination: MIDIEndpointRef

    /// Throws when CoreMIDI refuses the send, which the Coordinator treats as an unplug.
    func send(_ event: MIDIEvent) throws {
        var word = Self.ump(event)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        try check("MIDISendEventList", MIDISendEventList(port, destination, &list))
    }

    /// Denon's color message (#530) as UMP SysEx7 packets, one event list. The unit has taken it as a MIDI 1.0 SysEx
    /// packet; this UMP path is the one still to be seen on the unit.
    func send(color: LEDColorMessage) throws {
        // As the jog display sends its SysEx (CoreMIDIJogDisplay): a list in its own buffer, one packet per SysEx7 pair.
        let capacity = 1024
        let list = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8).bindMemory(to: MIDIEventList.self, capacity: 1)
        defer { list.deallocate() }
        var packet = MIDIEventListInit(list, ._1_0)
        for words in UMP.sysex7(color.bytes) {
            packet = MIDIEventListAdd(list, capacity, packet, 0, words.count, words)
        }
        try check("MIDISendEventList", MIDISendEventList(port, destination, list))
    }

    /// The output port is shared by every destination and lives as long as the MIDI client, so there is nothing to
    /// close per destination.
    func close() {}

    /// One UMP type 2 word (MIDI 1.0 channel voice, group 0). The smoke script checks the Play LED word exactly.
    static func ump(_ event: MIDIEvent) -> UInt32 {
        let (status, channel, data1, data2): (UInt32, UInt8, UInt8, UInt8) = switch event {
        case .noteOff(let c, let n, let v): (0x8, c, n, v)
        case .noteOn(let c, let n, let v): (0x9, c, n, v)
        case .controlChange(let c, let n, let v): (0xB, c, n, v)
        }
        return 0x2000_0000 | status << 20 | UInt32(channel & 0x0F) << 16 | UInt32(data1 & 0x7F) << 8 | UInt32(data2 & 0x7F)
    }
}

/// Lets the notify block, made before `self` exists, reach the system once it does. It also keeps the endpoints removed
/// since the last change (#429), by unique id: a removed endpoint may no longer answer, so its id comes from the last
/// time it was listed.
final class ChangeRelay: Sendable {
    private let action = Mutex<(@Sendable (Set<MIDIUniqueID>) -> Void)?>(nil)
    /// Others told of every change, such as the jog display's remembered ports (#552).
    private let observers = Mutex<[@Sendable () -> Void]>([])

    func observe(_ observer: @escaping @Sendable () -> Void) { observers.withLock { $0.append(observer) } }
    private let known = Mutex<[MIDIObjectRef: MIDIUniqueID]>([:])
    /// The other way round: each listed endpoint's ref by id, until it's removed (#595).
    private let refs = Mutex<[MIDIUniqueID: MIDIEndpointRef]>([:])
    private let removedIDs = Mutex<Set<MIDIUniqueID>>([])
    /// Where a change is handled (#595): not the main thread, where CoreMIDI's notifications arrive and the UI runs,
    /// and not the engine's loop. Observers (the snapshots' refreshes) run before the Coordinator hears of it.
    private let setup = DispatchQueue(label: "dev.ericdahl.ControllerBridge.midi-setup")

    func ref(for id: MIDIUniqueID) -> MIDIEndpointRef? { refs.withLock { $0[id] } }

    func set(_ action: @escaping @Sendable (Set<MIDIUniqueID>) -> Void) { self.action.withLock { $0 = action } }

    /// The endpoint as the Kit sees it, remembering its id for a later removal.
    func remember(_ ref: MIDIEndpointRef) -> MIDIEndpoint {
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &id)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
        known.withLock { $0[ref] = id }
        refs.withLock { $0[id] = ref }
        return MIDIEndpoint(id: id, name: (name?.takeRetainedValue() as String?) ?? "MIDI \(id)")
    }

    /// An object CoreMIDI removed: an endpoint we listed, by the id it had then, or one whose id still reads. Anything
    /// else (another device, an object we never listed) is ignored, so unplugging something unrelated can't make a
    /// controller reconnect and release what it holds.
    func removed(_ object: MIDIObjectRef) {
        var id: MIDIUniqueID = 0
        let read = MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &id) == noErr
        guard let removed = known.withLock({ $0[object] }) ?? (read ? id : nil) else { return }
        refs.withLock { if $0[removed] == object { $0[removed] = nil } }
        removedIDs.withLock { _ = $0.insert(removed) }
    }

    func fire() {
        let removed = removedIDs.withLock { ids in defer { ids = [] }; return ids }
        setup.async { [self] in
            for observer in observers.withLock({ $0 }) { observer() }
            action.withLock { $0 }?(removed)
        }
    }
}

private func check(_ call: String, _ status: OSStatus) throws {
    guard status == noErr else { throw CoreMIDIError.status(call, status) }
}
