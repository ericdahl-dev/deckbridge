// Denon's color message (#530): exact RGB for a pad or the ring, which the LC6000's stock top panel firmware takes on
// the Controller port, 7 bits a channel (#481; proven on the owner's unit). The only SysEx the bridge sends the
// controller, and only through the encoder below.

/// One color message: `F0 00 02 0B 7F 10 03 00 04 <note> <r> <g> <b> F7`. It has no public initializer: the encoder
/// makes it, so the command is always 03 and every value 0-127. Commands such as 78, 79, 7A and 7C, which write the
/// unit's settings, can't be expressed.
public struct LEDColorMessage: Equatable, Sendable {
    public let note: UInt8
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    fileprivate init(note: UInt8, red: UInt8, green: UInt8, blue: UInt8) {
        self.note = note
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The whole SysEx message, F0 through F7.
    public var bytes: [UInt8] {
        [0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x03, 0x00, 0x04, note & 0x7F, red & 0x7F, green & 0x7F, blue & 0x7F, 0xF7]
    }
}

/// Makes color messages for a profile's color-message LEDs: a note the profile lists that is its ring or one of its
/// pads. Nil for a profile without `leds.color_message`.
public struct LEDColorEncoder: Sendable {
    private let notes: Set<Int>
    /// The brightness every color is scaled to (#532), in percent, 0-100: 100 leaves it as it is.
    public let brightness: Int

    public init?(_ mapping: Mapping, brightness: Int = 100) {
        guard let listed = mapping.leds.colorMessage?.notes else { return nil }
        notes = Set(listed).intersection(Set(mapping.notes.pads + [mapping.leds.ring])).filter { (0...127).contains($0) }
        self.brightness = min(max(brightness, 0), 100)
    }

    /// Whether `note`'s LED takes the color message.
    public func takes(_ note: Int) -> Bool { notes.contains(note) }

    /// The message for `note` in an 8-bit color (each channel clamped to 0-255, scaled to `brightness` rounding down,
    /// then its top 7 bits), or nil when the note's LED doesn't take it.
    public func message(note: Int, rgb: [Int]) -> LEDColorMessage? {
        guard notes.contains(note), rgb.count == 3 else { return nil }
        let seven = rgb.map { UInt8((min(max($0, 0), 255) * brightness / 100) >> 1) }
        return LEDColorMessage(note: UInt8(note), red: seven[0], green: seven[1], blue: seven[2])
    }
}

/// Paces color messages (#531): at most one per `gap` seconds. A message that can't go yet waits; a newer one for the
/// same LED replaces it in place. With a gap of 0 (the bridge's, until a burst test on the unit says otherwise) every
/// message goes out at once.
public struct ColorPacer: Sendable {
    public let gap: Double
    private var waiting: [LEDColorMessage] = []
    private var last: Double?

    public init(gap: Double) { self.gap = gap }

    /// What goes out now for `message`: itself, or nothing while it waits.
    public mutating func send(_ message: LEDColorMessage, at now: Double) -> [LEDColorMessage] {
        if gap <= 0 { return [message] }
        if let index = waiting.firstIndex(where: { $0.note == message.note }) {
            waiting[index] = message
            return []
        }
        guard waiting.isEmpty, ready(now) else {
            waiting.append(message)
            return []
        }
        last = now
        return [message]
    }

    /// What goes out on a tick: the oldest waiting message, once its gap has passed.
    public mutating func tick(at now: Double) -> [LEDColorMessage] {
        guard !waiting.isEmpty, ready(now) else { return [] }
        last = now
        return [waiting.removeFirst()]
    }

    private func ready(_ now: Double) -> Bool { last.map { now - $0 >= gap - 1e-9 } ?? true }
}

/// Settings' brightness slider for the color-message LEDs (#532), the user's pick: 10% to 100% in 10% steps, no 0.
public enum LightBrightness {
    public static let steps = Array(stride(from: 10, through: 100, by: 10))

    /// `percent` on the nearest step, within 10-100 (a half rounds up).
    public static func snapped(_ percent: Int) -> Int {
        min(max((percent + 5) / 10 * 10, 10), 100)
    }

    public static func label(_ percent: Int) -> String { "\(percent)%" }
}
