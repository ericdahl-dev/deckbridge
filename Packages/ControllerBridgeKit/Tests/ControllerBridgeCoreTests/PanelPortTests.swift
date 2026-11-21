@testable import ControllerBridgeCore
import Testing

/// The deck panel's USB cable (#667): its port is found by the board's USB bridge (WCH CH340, 1a86:7522, read from
/// the owner's board with ioreg), never by the node's name, which depends on the driver.
@Suite("Display feed: finding the deck panel's port")
struct PanelPortTests {
    static let bluetooth = SerialPort(path: "/dev/cu.Bluetooth-Incoming-Port", vendor: nil, product: nil)
    static let otherWCH = SerialPort(path: "/dev/cu.usbserial-110", vendor: 0x1A86, product: 0x7523)

    @Test("the board's bridge is picked, whatever its node is called")
    func theBoardsBridgeIsPicked() {
        let board = SerialPort(path: "/dev/cu.usbserial-210", vendor: 0x1A86, product: 0x7522)
        #expect(PanelPort.find(in: [Self.bluetooth, Self.otherWCH, board]) == board)
    }

    @Test("with no board plugged in, nothing is picked")
    func withNoBoardNothingIsPicked() {
        #expect(PanelPort.find(in: [Self.bluetooth, Self.otherWCH]) == nil)
    }
}
