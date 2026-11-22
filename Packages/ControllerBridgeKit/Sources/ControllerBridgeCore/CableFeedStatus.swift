// The USB cable's status line in Settings (#667): from its switch and the deck panel's port.

/// The panel's serial port, as the app's adapter last found it.
public enum CablePortState: Equatable, Sendable {
    /// No deck panel among the Mac's serial ports.
    case noPanel
    /// Open: the feed goes out on it.
    case open
    /// Another app holds it (opened exclusively): the Firmware Updater, or a serial monitor.
    case busy
    /// It couldn't be opened, or stopped taking data: the reason.
    case failed(String)
    /// Lent to the Firmware Updater for an update (#710): taken back when it's done.
    case lent
}

public struct CableFeedStatus: Equatable, Sendable {
    public var cable: Bool
    public var port: CablePortState

    public init(cable: Bool, port: CablePortState) {
        self.cable = cable
        self.port = port
    }

    /// Shown in the error color.
    public var isProblem: Bool {
        guard cable else { return false }
        switch port {
        case .busy, .failed: return true
        case .noPanel, .open, .lent: return false
        }
    }

    /// The line Settings shows.
    public var text: String {
        guard cable else { return "Off" }
        switch port {
        case .noPanel: return "No deck panel plugged into this Mac"
        case .open: return "Sending to the deck panel on USB"
        case .busy: return "Not sending: another app has the panel's port open, such as the Firmware Updater or a serial monitor"
        case .failed(let reason): return "Not sending: \(reason)"
        case .lent: return "Paused: the Firmware Updater is using the panel's USB cable"
        }
    }
}
