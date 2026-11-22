import ControllerBridgePresentation
import Testing

/// MIDI sources no controller profile matches (#43). A Mac nearly always has some (IAC Bus, virtual ports), so they
/// sit in a quiet gray list, unless no controller is connected: then the first one is probably the user's controller.
/// Each one that isn't a virtual port gets Help add it… either way (#329).
@Suite("Other MIDI devices")
struct OtherDevicesTests {
    // Natural case, so VoiceOver reads words rather than letters; the view shows it uppercase (#67).
    @Test("With a controller connected, unmatched devices are one quiet gray list, with no orange")
    func quietListWhileConnected() {
        let devices = OtherDevices(unmatched: ["IAC Bus 1", "DDJ-FLX4"], controllerConnected: true)
        #expect(devices.highlighted == nil)
        #expect(devices.summary == "Other MIDI devices (2)")
        #expect(devices.rows == ["IAC Bus 1 · no profile", "DDJ-FLX4 · no profile"])
    }

    @Test("With no controller connected, the first unmatched device is the orange NO PROFILE row; the rest stay gray")
    func firstIsHighlightedWithoutAController() {
        let devices = OtherDevices(unmatched: ["DDJ-FLX4", "IAC Bus 1"], controllerConnected: false)
        #expect(devices.highlighted == StatusLight(label: "DDJ-FLX4", word: "No profile", tone: .attention, kind: .device))
        #expect(devices.summary == "Other MIDI devices (1)")
        #expect(devices.rows == ["IAC Bus 1 · no profile"])
    }

    @Test("No unmatched devices: no row and no list")
    func nothingToShow() {
        #expect(OtherDevices(unmatched: [], controllerConnected: false) == OtherDevices(unmatched: [], controllerConnected: true))
        let devices = OtherDevices(unmatched: [], controllerConnected: false)
        #expect(devices.highlighted == nil && devices.summary == nil && devices.rows.isEmpty)
    }

    // MARK: Help add it (#200)

    @Test("The highlighted device gets the offer: it isn't supported yet, Help add it…")
    func offer() {
        let devices = OtherDevices(unmatched: ["DDJ-FLX4"], controllerConnected: false)
        #expect(devices.offers == [CaptureOffer(device: "DDJ-FLX4", text: "DDJ-FLX4 isn't supported yet.", action: "Help add it…")])
    }

    // MARK: Help add it, with a controller connected (#329)

    @Test("With an LC6000 connected, an unmatched device still gets the offer, and its capture preselects that device")
    func offerWhileConnected() {
        let devices = OtherDevices(unmatched: ["DDJ-FLX4"], controllerConnected: true)
        #expect(devices.offers == [CaptureOffer(device: "DDJ-FLX4", text: "DDJ-FLX4 isn't supported yet.", action: "Help add it…")])
        // Still quiet: no orange row, and the device stays in the gray list.
        #expect(devices.highlighted == nil)
        #expect(devices.rows == ["DDJ-FLX4 · no profile"])
    }

    @Test("Every unmatched device gets its own offer, in order; virtual ports and the LC6000's WD port never do")
    func everyUnmatchedDeviceIsOffered() {
        let devices = OtherDevices(
            unmatched: ["IAC Driver Bus 1", "DDJ-FLX4", "Network Session 1", "MC7000"],
            ownPorts: [(name: "LC6000 PRIME WD", of: "Denon LC6000 PRIME")], controllerConnected: true
        )
        #expect(devices.offers.map(\.device) == ["DDJ-FLX4", "MC7000"])
        #expect(devices.offers.last?.text == "MC7000 isn't supported yet.")
        #expect(devices.summary == "Other MIDI devices (5)")
    }

    @Test("A known controller's other port (the LC6000's WD) is never highlighted or offered: it's listed as part of it")
    func ownPorts() {
        let devices = OtherDevices(unmatched: [], ownPorts: [(name: "LC6000 PRIME WD", of: "Denon LC6000 PRIME")], controllerConnected: false)
        #expect(devices.highlighted == nil)
        #expect(devices.offers.isEmpty)
        #expect(devices.summary == "Other MIDI devices (1)")
        #expect(devices.rows == ["LC6000 PRIME WD · part of the Denon LC6000 PRIME"])
    }

    @Test("macOS's own virtual ports (IAC Driver, Network sessions) are never taken for the DJ's controller")
    func virtualPortsAreNotControllers() {
        let devices = OtherDevices(unmatched: ["IAC Driver Bus 1", "DDJ-FLX4"], controllerConnected: false)
        #expect(devices.highlighted?.label == "DDJ-FLX4")
        #expect(devices.rows == ["IAC Driver Bus 1 · no profile"])
        let virtualOnly = OtherDevices(unmatched: ["IAC Driver Bus 1", "Network Session 1"], controllerConnected: false)
        #expect(virtualOnly.highlighted == nil)
        #expect(virtualOnly.offers.isEmpty)
        #expect(virtualOnly.summary == "Other MIDI devices (2)")
    }
}
