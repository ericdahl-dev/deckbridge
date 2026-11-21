// Finding the deck panel on the USB cable (#667). Pure: the app's IOKit adapter lists the ports.

/// A serial port as IOKit lists it: its callout node, and its USB IDs when it is a USB device.
public struct SerialPort: Equatable, Sendable {
    public var path: String
    public var vendor: Int?
    public var product: Int?

    public init(path: String, vendor: Int?, product: Int?) {
        self.path = path
        self.vendor = vendor
        self.product = product
    }
}

public enum PanelPort {
    /// The CrowPanel's USB bridge: WCH CH340, 1a86:7522 (read from the owner's board with ioreg).
    static let vendor = 0x1A86
    static let product = 0x7522

    /// The deck panel's port, by the board's USB IDs, never by the node's name: that depends on the driver.
    public static func find(in ports: [SerialPort]) -> SerialPort? {
        ports.first { $0.vendor == vendor && $0.product == product }
    }
}
