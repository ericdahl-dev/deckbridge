import PortHandoff
import Testing
import UpdaterScreen

/// What the screen says about borrowing the panel's port from DeckBridge (#710).
@Suite("Updater: the screen when DeckBridge is asked for the panel's port")
struct HandoffScreenTests {
    @Test("No answer: say plainly to turn off Send over the USB cable or quit DeckBridge; lent: nothing to say")
    func noAnswer() {
        #expect(UpdaterScreen.handoff(.noAnswer)
            == "DeckBridge didn't let go of the panel's USB cable. Turn off \"Send over the USB cable\" in DeckBridge, or quit DeckBridge, then look again.")
        #expect(UpdaterScreen.handoff(.lent) == nil)
    }
}
