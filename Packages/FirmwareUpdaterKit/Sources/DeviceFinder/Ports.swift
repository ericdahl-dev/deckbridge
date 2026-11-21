/// The ports the device finder looks through (#685). Each only reads: none has a way to send to a device, so finding
/// can't write. The app's adapters are IOKit, CoreMIDI and a serial port opened with DTR and RTS held off.

/// A USB device on the Mac, as the finder needs it. No serial number: it is never read.
public struct USBDevice: Sendable, Hashable {
    public let vendor: UInt16
    public let product: UInt16
    public let name: String
    /// The serial port a driver made for it (`/dev/cu.…`), or nil when no driver took it.
    public let serialPort: String?

    public init(vendor: UInt16, product: UInt16, name: String, serialPort: String? = nil) {
        self.vendor = vendor
        self.product = product
        self.name = name
        self.serialPort = serialPort
    }
}

/// The USB devices plugged in now.
public protocol USBDevices: Sendable {
    func devices() async -> [USBDevice]
}

/// The MIDI ports' names: sources and destinations together.
public protocol MIDIPorts: Sendable {
    func names() async -> [String]
}

/// A panel's serial lines. Listening only: the port opens with DTR and RTS held off, so the panel isn't reset, and
/// nothing is written to it. A later ticket may add a version question here (#695).
public protocol PanelSerial: Sendable {
    /// The lines the panel printed on `port` at `baud` within `seconds`.
    func listen(on port: String, baud: Int, for seconds: Double) async -> [String]
}

/// Where the finder writes what it found: a file the owner can send.
public protocol LogSink: Sendable {
    func log(_ line: String)
}
