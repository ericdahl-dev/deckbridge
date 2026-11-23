/// The ports the device finder looks through (#685). Each only reads, but for one question to our own deck panel: the
/// text line "version" (#715). The app's adapters are IOKit, CoreMIDI and a serial port opened with DTR and RTS held off.

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

/// What listening to a panel's port gave.
public enum Listened: Sendable, Equatable {
    case lines([String])
    /// Another app holds the port exclusively (DeckBridge, while it sends over the USB cable): the open failed busy.
    case busy
}

/// A panel's serial lines. The port opens with DTR and RTS held off, so the panel isn't reset. The only thing ever
/// written is the finder's `question`.
public protocol PanelSerial: Sendable {
    /// The lines the panel printed on `port` at `baud` within `seconds`, after `question` (if any) was written.
    func listen(on port: String, baud: Int, for seconds: Double, asking question: String?) async -> Listened
}

/// Where the finder writes what it found: a file the owner can send.
public protocol LogSink: Sendable {
    func log(_ line: String)
}
