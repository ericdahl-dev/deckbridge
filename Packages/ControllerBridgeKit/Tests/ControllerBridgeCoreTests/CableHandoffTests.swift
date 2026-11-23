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

    @Test("Done with the switch on: look again, so the port reopens and the full snapshot goes (its opening, #667)")
    func doneReclaims() {
        var handoff = CableHandoff()
        _ = handoff.releaseAsked(holding: true)
        #expect(handoff.doneAsked(cableOn: true) == [.lookAgain])
        #expect(handoff.mayLook)
    }

    @Test("Done with the switch off: nothing to take back; done again, or never asked: nothing")
    func doneWithSwitchOff() {
        var handoff = CableHandoff()
        _ = handoff.releaseAsked(holding: false)
        #expect(handoff.doneAsked(cableOn: false) == [])
        #expect(handoff.mayLook)
        #expect(handoff.doneAsked(cableOn: true) == [])
        var never = CableHandoff()
        #expect(never.doneAsked(cableOn: true) == [])
    }

    @Test("The switch turned on while lent doesn't take the port; turned off, the lend ends (after an updater crash)")
    func switchWhileLent() {
        var handoff = CableHandoff()
        _ = handoff.releaseAsked(holding: false)
        handoff.switchChanged(on: true)
        #expect(!handoff.mayLook)
        handoff.switchChanged(on: false)
        #expect(handoff.mayLook)
        #expect(handoff.doneAsked(cableOn: false) == [])
    }

    /// The Firmware Updater's FirmwareUpdaterKit (PortHandoff) has the same names.
    @Test("The signals' names, the same in both apps")
    func names() {
        #expect(CableHandoff.releaseName == "dev.ericdahl.deckbridge.panel-port.release")
        #expect(CableHandoff.releasedName == "dev.ericdahl.deckbridge.panel-port.released")
        #expect(CableHandoff.doneName == "dev.ericdahl.deckbridge.panel-port.done")
    }

    /// The debug trace's line for each step (#710's owner run: deckbridge.log had nothing, so a lend couldn't be told
    /// from no ask at all). `note` is the last call's line; nil when that call changed nothing.
    @Test("Each step leaves a line for the trace: asked, done, done with the switch off, switch off while lent")
    func notes() {
        var handoff = CableHandoff()
        _ = handoff.releaseAsked(holding: true)
        #expect(handoff.note == "cable: the Firmware Updater asked for the port; closed it, lent")
        _ = handoff.doneAsked(cableOn: true)
        #expect(handoff.note == "cable: the Firmware Updater is done; taking the port back")
        _ = handoff.releaseAsked(holding: false)
        #expect(handoff.note == "cable: the Firmware Updater asked for the port; it wasn't open, lent")
        _ = handoff.doneAsked(cableOn: false)
        #expect(handoff.note == "cable: the Firmware Updater is done; switch off, port stays closed")
        _ = handoff.doneAsked(cableOn: true)
        #expect(handoff.note == "cable: the Firmware Updater said done, but the port wasn't lent")
        _ = handoff.releaseAsked(holding: false)
        handoff.switchChanged(on: true)
        #expect(handoff.note == nil)
        handoff.switchChanged(on: false)
        #expect(handoff.note == "cable: switch off while lent; the lend ends")
        handoff.switchChanged(on: true)
        #expect(handoff.note == nil)
    }
}
