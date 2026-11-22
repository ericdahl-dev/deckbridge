/// Everything the Coordinator reacts to, in one Sendable type.
public enum PipeEvent: Equatable, Sendable {
    case midi(MIDIEvent, source: MIDIEndpoint.ID)
    /// One UDP datagram from Syndicate, still OSC-encoded.
    case udp([UInt8])
    case tick
    /// MIDI devices were added or removed: the Coordinator re-reads them. `removed` is every endpoint removed since the
    /// last one, even if already back (#429).
    case devicesChanged(removed: Set<MIDIEndpoint.ID>)
    /// The Mac is about to sleep, or just woke.
    case sleep
    case wake
    /// The Diagnostics window opened or closed (#26).
    case diagnostics(open: Bool)
    /// The built-in demo controller (#64) on or off.
    case demo(on: Bool)
    /// A message from the jog display's WD port (#165): the unit's upload answers.
    case jogDisplayReply([UInt8])
    /// A change the app asks of the Coordinator (#386), routed by the Engine from `command.routing`.
    case command(Coordinator.Command)
    /// Quit: release everything and end the loop. Always the last event.
    case stop
}

/// One ordered stream fed by every adapter: the CoreMIDI callback, the UDP reader and the tick timer.
///
/// Each producer's events arrive in the order it sent them. Across producers there is only arrival order.
public struct EventPipe: Sendable {
    public let events: AsyncStream<PipeEvent>
    public let producer: Producer

    public init() {
        // Unbounded: a dropped note off would leave a held button stuck.
        let (stream, continuation) = AsyncStream<PipeEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        producer = Producer(continuation: continuation)
    }

    /// Safe from any thread, including the CoreMIDI realtime thread. Every call is synchronous and never waits.
    public struct Producer: Sendable {
        let continuation: AsyncStream<PipeEvent>.Continuation

        public func midi(_ event: MIDIEvent, source: MIDIEndpoint.ID) { continuation.yield(.midi(event, source: source)) }
        /// Any Coordinator command (#386), in order with everything else sent.
        public func send(_ command: Coordinator.Command) { continuation.yield(.command(command)) }
        public func udp(_ datagram: [UInt8]) { continuation.yield(.udp(datagram)) }
        public func tick() { continuation.yield(.tick) }
        public func devicesChanged(removed: Set<MIDIEndpoint.ID> = []) { continuation.yield(.devicesChanged(removed: removed)) }
        public func sleep() { continuation.yield(.sleep) }
        public func wake() { continuation.yield(.wake) }
        public func diagnostics(open: Bool) { continuation.yield(.diagnostics(open: open)) }
        public func demo(on: Bool) { continuation.yield(.demo(on: on)) }
        public func jogDisplayReply(_ bytes: [UInt8]) { continuation.yield(.jogDisplayReply(bytes)) }
        /// Quit. Queues the stop behind everything already sent, then closes the pipe, so nothing after it is handled.
        public func stop() {
            continuation.yield(.stop)
            continuation.finish()
        }
        public func finish() { continuation.finish() }
    }
}
