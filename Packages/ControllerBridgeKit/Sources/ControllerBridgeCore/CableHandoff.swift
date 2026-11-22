// Lending the deck panel's USB port to the Firmware Updater (#710): when the updater needs the port and DeckBridge holds
// it for the cable feed, the updater asks; DeckBridge lets go and says so, and takes it back when told the update is
// done. The app carries the asks and answers between the two apps (on this Mac only) and applies the actions.

public struct CableHandoff: Sendable {
    public enum Action: Equatable, Sendable {
        /// Close the panel's port.
        case closePort
        /// Tell the updater the port is free.
        case tellReleased
        /// Look for the port again: it opens, and the opening sends the full snapshot (cableFeedReady).
        case lookAgain
    }

    /// The signals between the two apps (on this Mac only: the app posts and hears them, names only). Any local process
    /// can post them; the worst a stray one does is have DeckBridge let go of the port until done or a switch toggle.
    public static let releaseName = "dev.ericdahl.deckbridge.panel-port.release"
    public static let releasedName = "dev.ericdahl.deckbridge.panel-port.released"
    public static let doneName = "dev.ericdahl.deckbridge.panel-port.done"

    /// Lent to the updater: until it's done, DeckBridge doesn't look for the port, so it never takes it mid-update.
    public private(set) var lent = false

    /// The debug trace's line for the last call (#710's owner run had none); nil when that call changed nothing.
    public private(set) var note: String?

    public init() {}

    /// Whether DeckBridge may look for the panel's port and open it.
    public var mayLook: Bool { !lent }

    /// The updater asks for the port. `holding`: DeckBridge has it open now.
    public mutating func releaseAsked(holding: Bool) -> [Action] {
        lent = true
        note = "cable: the Firmware Updater asked for the port; " + (holding ? "closed it, lent" : "it wasn't open, lent")
        return holding ? [.closePort, .tellReleased] : [.tellReleased]
    }

    /// The updater is done with the port: take it back if the switch is on. Not lent, nothing.
    public mutating func doneAsked(cableOn: Bool) -> [Action] {
        guard lent else {
            note = "cable: the Firmware Updater said done, but the port wasn't lent"
            return []
        }
        lent = false
        note = "cable: the Firmware Updater is done; " + (cableOn ? "taking the port back" : "switch off, port stays closed")
        return cableOn ? [.lookAgain] : []
    }

    /// The cable's switch changed. On while lent: still lent. Off: the lend ends, so turning it off and on takes the port
    /// back even if the updater never said it was done (it crashed or was quit).
    public mutating func switchChanged(on: Bool) {
        note = !on && lent ? "cable: switch off while lent; the lend ends" : nil
        if !on { lent = false }
    }
}
