// The Coordinator's view of the outside world. The app supplies CoreMIDI, UDP and a real clock; tests supply fakes.

/// One MIDI 1.0 channel voice message, already parsed out of the CoreMIDI callback.
public enum MIDIEvent: Equatable, Sendable {
    /// `channel` is 0-based: MIDI channel 1 is 0.
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
}

/// A MIDI source or destination.
public struct MIDIEndpoint: Hashable, Sendable, Identifiable, Codable {
    /// The CoreMIDI unique id: stable across replugs, unlike the endpoint reference.
    public var id: Int32
    public var name: String

    public init(id: Int32, name: String) {
        self.id = id
        self.name = name
    }
}

/// Sends MIDI to one destination, such as the controller's LEDs.
public protocol MIDIOutput: Sendable {
    /// Throws when the destination is gone, which counts as an unplug.
    func send(_ event: MIDIEvent) throws
    /// Sends Denon's color message (#530) for a pad or the ring: the only SysEx the bridge sends a controller, made
    /// only by `LEDColorEncoder`.
    func send(color: LEDColorMessage) throws
    /// Closes the port. Nothing is sent after this.
    func close()
}

/// The MIDI devices: what is connected, and opening ports on them. A connected source's events reach the
/// Coordinator through `Coordinator.midi(_:source:)`.
public protocol MIDISystem: Sendable {
    var sources: [MIDIEndpoint] { get }
    var destinations: [MIDIEndpoint] { get }
    func connect(source: MIDIEndpoint) throws
    func disconnect(source: MIDIEndpoint)
    func openOutput(destination: MIDIEndpoint) throws -> any MIDIOutput
}

/// Sends OSC to Syndicate.
public protocol OSCSender: Sendable {
    func send(_ message: OSCMessage)
    /// The messages as one OSC bundle (#636), where the sender can put them in one datagram.
    func send(bundle messages: [OSCMessage])
}

/// A sender whose sends leave later, on a queue of its own (#651): `flush` waits for them.
public protocol OSCFlushing {
    func flush(timeout: Double)
}

extension OSCSender {
    /// A sender with no bundles of its own sends the messages one by one.
    public func send(bundle messages: [OSCMessage]) {
        for message in messages { send(message) }
    }
}

/// Monotonic time in seconds.
public protocol Clock: Sendable {
    var now: Double { get }
}

/// Where the Coordinator writes what happened, for the diagnostics.
public protocol LogSink: Sendable {
    func log(_ line: String)
}
