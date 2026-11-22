import ControllerBridgeCore
import Testing

/// Lending the deck panel's USB port to the Firmware Updater (#710): asked, DeckBridge lets go of the port and says so;
/// told the update is done, it takes the port back. The app applies the actions (PanelCable); the rules are here.
@Suite("Display feed: lending the cable's port to the Firmware Updater")
struct CableHandoffTests {
    @Test("Asked while holding the port: close it, then say it's released; no looking for the port while lent")
    func releaseWhileHolding() {
        var handoff = CableHandoff()
        #expect(handoff.mayLook)
        #expect(handoff.releaseAsked(holding: true) == [.closePort, .tellReleased])
        #expect(!handoff.mayLook)
    }

    @Test("Asked while not holding it (switch off, or no panel): released at once, and still no looking while lent")
    func releaseWhileNotHolding() {
        var handoff = CableHandoff()
        #expect(handoff.releaseAsked(holding: false) == [.tellReleased])
        #expect(!handoff.mayLook)
    }
}
