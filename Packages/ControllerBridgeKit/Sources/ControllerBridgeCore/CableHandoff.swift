// Lending the deck panel's USB port to the Firmware Updater (#710): when the updater needs the port and DeckBridge holds
// it for the cable feed, the updater asks; DeckBridge lets go and says so, and takes it back when told the update is
// done. The app carries the asks and answers between the two apps (on this Mac only) and applies the actions.

public struct CableHandoff: Sendable {
    public enum Action: Equatable, Sendable {
        /// Close the panel's port.
        case closePort
        /// Tell the updater the port is free.
        case tellReleased
    }

    /// Lent to the updater: until it's done, DeckBridge doesn't look for the port, so it never takes it mid-update.
    public private(set) var lent = false

    public init() {}

    /// Whether DeckBridge may look for the panel's port and open it.
    public var mayLook: Bool { !lent }

    /// The updater asks for the port. `holding`: DeckBridge has it open now.
    public mutating func releaseAsked(holding: Bool) -> [Action] {
        lent = true
        return holding ? [.closePort, .tellReleased] : [.tellReleased]
    }
}
