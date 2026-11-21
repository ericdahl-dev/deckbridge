// The display feed over the USB cable (#667): the same OSC packets as over Wi-Fi, each as one SLIP frame on the port.

/// An open serial port, as the app's adapter has it: writes the bytes whole, in order.
public protocol BytePort: Sendable {
    func write(_ bytes: [UInt8])
}

/// The cable's OSC sender: one frame per packet, in one write, so a frame is never split between two sends. The app
/// puts it behind its own DisplayFeedQueue, so a slow port never makes the Wi-Fi feed drop.
public final class CableFeedSender: OSCSender {
    private let port: any BytePort

    public init(_ port: any BytePort) {
        self.port = port
    }

    public func send(_ message: OSCMessage) {
        port.write(SLIP.frame(message.encoded()))
    }

    public func send(bundle messages: [OSCMessage]) {
        port.write(SLIP.frame(OSCPacket.bundle(messages)))
    }
}
