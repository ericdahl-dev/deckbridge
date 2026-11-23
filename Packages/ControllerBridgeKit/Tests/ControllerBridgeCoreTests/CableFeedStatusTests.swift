import ControllerBridgeCore
import Testing

/// The USB cable's status line in Settings (#667): from its switch and the panel's port, so a cable that can't send
/// never fails silently.
@Suite("Display feed: the USB cable's status line")
struct CableFeedStatusTests {
    @Test("Off whatever the port; on, it says whether the panel is plugged in and taking the feed")
    func lines() {
        #expect(CableFeedStatus(cable: false, port: .open).text == "Off")
        #expect(CableFeedStatus(cable: true, port: .noPanel).text == "No deck panel plugged into this Mac")
        #expect(CableFeedStatus(cable: true, port: .open).text == "Sending to the deck panel on USB")
        #expect(CableFeedStatus(cable: true, port: .busy).text
            == "Not sending: another app has the panel's port open, such as the DeckBridge Firmware Updater or a serial monitor")
        #expect(CableFeedStatus(cable: true, port: .failed("Permission denied")).text == "Not sending: Permission denied")
        #expect(CableFeedStatus(cable: true, port: .lent).text == "Paused: the DeckBridge Firmware Updater is using the panel's USB cable")
    }

    @Test("Only busy and failed are problems")
    func problems() {
        #expect(CableFeedStatus(cable: true, port: .busy).isProblem)
        #expect(CableFeedStatus(cable: true, port: .failed("x")).isProblem)
        #expect(!CableFeedStatus(cable: true, port: .noPanel).isProblem)
        #expect(!CableFeedStatus(cable: true, port: .open).isProblem)
        #expect(!CableFeedStatus(cable: false, port: .busy).isProblem)
        #expect(!CableFeedStatus(cable: true, port: .lent).isProblem)  // asked for, not a fault (#710)
    }
}
