import Foundation

/// A debug capture of Syndicate's full-rate meter stream (#582): every Mixer/CHn/Meter value with its time since the
/// start, for a set time, as CSV. For deciding the meter's scale from data; the trace keeps only 5 a second.
struct MeterCapture {
    let start: Double, seconds: Double
    private(set) var lines = ["seconds,channel,value"]

    init(start: Double, seconds: Double) {
        self.start = start
        self.seconds = seconds
    }

    /// Whether the capture's time is up at `time`.
    func done(at time: Double) -> Bool { time - start >= seconds - 1e-9 }

    /// Records the message if it's a channel meter and the capture is still running.
    mutating func record(_ message: OSCMessage, at time: Double) {
        guard !done(at: time), let value = message.arguments.first?.number else { return }
        let address = message.address.lowercased()
        guard let channel = (1...4).first(where: { address.hasSuffix("/mixer/ch\($0)/meter") }) else { return }
        lines.append(String(format: "%.3f,%d,%.4f", time - start, channel, value))
    }

    var csv: String { lines.joined(separator: "\n") + "\n" }
}
