/// Watches the captured controller's source (#315): the app hands in the sources CoreMIDI lists as online after each
/// change, and hears once when it went and once when it came back. Presence is the online list, not a lookup by id:
/// an unplugged USB device's endpoint usually stays findable, marked offline.
public struct CaptureWatch: Sendable {
    public enum Change: Equatable, Sendable {
        /// Gone: the window says so and waits.
        case disconnected
        /// Back: listen again, and pause the bridge again (an unplug had ended its pause).
        case reconnected
    }

    public let source: Int32
    private var present = true

    public init(source: Int32) {
        self.source = source
    }

    /// The online sources' unique ids now: what changed for the watched one, if anything.
    public mutating func sourcesChanged(online: [Int32]) -> Change? {
        let now = online.contains(source)
        defer { present = now }
        guard now != present else { return nil }
        return now ? .reconnected : .disconnected
    }
}
