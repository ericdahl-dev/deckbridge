import Foundation

/// The jog display simulator's words (#221): Diagnostics › Jog display draws each deck's display from the same
/// renderer as the hardware upload (#165); these are the parts around the picture.

/// What one deck's display shows, as VoiceOver reads it: the picture itself says nothing to a screen reader.
public struct JogDeckSummary: Equatable, Sendable {
    public var deck: Int
    public var title: String?
    public var key: String?
    public var bpm: Double?
    public var beat: Int?

    public init(deck: Int, title: String?, key: String?, bpm: Double?, beat: Int?) {
        self.deck = deck
        self.title = title
        self.key = key
        self.bpm = bpm
        self.beat = beat
    }

    /// "Deck 1, Daybreak, A#m, 128 BPM, beat 2", leaving out what isn't known. An empty title is an empty deck, as
    /// Syndicate's TrackInfo sends it (#209).
    public var spoken: String {
        guard let title, !title.isEmpty else { return "Deck \(deck), no track loaded" }
        var parts = ["Deck \(deck)", title]
        if let key, !key.isEmpty { parts.append(key) }
        if let bpm, bpm > 0 {
            parts.append((bpm.rounded() == bpm ? String(Int(bpm)) : String(bpm)) + " BPM")
        }
        if let beat { parts.append("beat \(beat)") }
        return parts.joined(separator: ", ")
    }
}

/// The last upload to one deck's display, for the readout under its preview (#221), so the simulator doubles as a
/// display debugger.
public enum JogUploadStatus: Equatable, Sendable {
    /// No LC6000 is connected: the preview is drawn, nothing is sent.
    case notConnected
    /// Connected, but no image has been sent yet.
    case notUploaded
    /// An image went to `slot`, `bytes` long, and the unit accepted or refused it (JogDisplay.Reply).
    case uploaded(slot: Int, bytes: Int, at: Date, accepted: Bool)

    /// "Slot 2 · 14,812 bytes · 12:04:31 · Accepted". The time is local; tests pass a time zone.
    public func readout(timeZone: TimeZone = .current) -> String {
        switch self {
        case .notConnected: return "No LC6000 connected: preview only"
        case .notUploaded: return "Nothing uploaded yet"
        case .uploaded(let slot, let bytes, let at, let accepted):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let time = calendar.dateComponents([.hour, .minute, .second], from: at)
            let clock = [time.hour, time.minute, time.second].map { String(format: "%02d", $0 ?? 0) }.joined(separator: ":")
            return "Slot \(slot) · \(Self.grouped(bytes)) bytes · \(clock) · \(accepted ? "Accepted" : "Refused")"
        }
    }

    /// 14812 as "14,812", the same on every Mac whatever its region.
    private static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out += "," }
            out.append(digit)
        }
        return out
    }
}

/// Holds a fast stream (the needle's angle, ~100 updates a second while playing) to at most one redraw per `interval`
/// (#221: ~30 Hz), always ending on the newest value. The view offers each value as it arrives and ticks on its
/// display timer; whatever either returns is drawn.
public struct RedrawLimiter<Value: Sendable>: Sendable {
    public let interval: Double
    private var lastDraw: Double?
    private var waiting: Value?

    public init(interval: Double) {
        self.interval = interval
    }

    /// A new value at time `now` (seconds): returned to draw now, or held until the interval has passed.
    public mutating func offer(_ value: Value, at now: Double) -> Value? {
        if let lastDraw, now - lastDraw < interval {
            waiting = value
            return nil
        }
        lastDraw = now
        waiting = nil
        return value
    }

    /// The held value, once the interval since the last draw has passed; nil otherwise.
    public mutating func tick(at now: Double) -> Value? {
        guard let value = waiting, let lastDraw, now - lastDraw >= interval else { return nil }
        self.lastDraw = now
        waiting = nil
        return value
    }
}

/// Where the simulator draws the needle (#221), from the pitch bend the Coordinator sends to the display (#165).
public enum JogNeedleAngle {
    /// The hand's angle in degrees, clockwise from 12 o'clock: pitchBend / 16384 of a turn (0…16383). A quarter turn
    /// is one beat, from 0 on beat 1. PROVISIONAL: the #165 hardware spike confirms where the unit puts zero and which
    /// way it turns; flip it here, the one place the simulator reads it.
    public static func degrees(pitchBend: Int) -> Double {
        Double(pitchBend) / 16_384 * 360
    }
}

/// The simulator's view of the jog display (#221), built from the display driver's events. The App maps each
/// `JogDisplayEvent` (ControllerBridgeCore) to one `Input`, timestamping uploads, so this target stays free of Core.
public struct JogSimulator: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        case connected
        case disconnected
        /// An image for `deck` started into `slot`; that deck is now the one in front.
        case uploadStarted(slot: Int, deck: Int, bytes: Int, at: Date)
        /// The unit shows `slot`.
        case shown(slot: Int)
        /// The upload in progress was refused, or got no answer.
        case failed
        /// A deck's needle: its own phase in the bar (#165, the user's pick).
        case needle(deck: Int, pitchBend: Int)
        /// The master clock's beat (1-4): the lit ring segment on every deck.
        case masterBeat(Int)
        /// Whether `deck` is playing, from Syndicate's feedback (#317): not the play light, which blinks while paused.
        case playing(deck: Int, Bool)
    }

    private struct Upload: Equatable, Sendable {
        var slot: Int, bytes: Int, at: Date
        var accepted: Bool?
    }

    private var connected = false
    /// The deck the unit is showing: the last one an upload started for.
    public private(set) var front: Int?
    private var uploads: [Int: Upload] = [:]
    private var needles: [Int: Int] = [:]
    private var plays: [Int: Bool] = [:]
    private var master: Int?

    public init() {}

    public mutating func apply(_ input: Input) {
        switch input {
        case .connected: connected = true
        case .disconnected: connected = false
        case .uploadStarted(let slot, let deck, let bytes, let at):
            front = deck
            uploads[deck] = Upload(slot: slot, bytes: bytes, at: at, accepted: nil)
        case .shown(let slot):
            if let front, uploads[front]?.slot == slot { uploads[front]?.accepted = true }
        case .failed:
            if let front { uploads[front]?.accepted = false }
        case .needle(let deck, let pitchBend): needles[deck] = pitchBend
        case .masterBeat(let beat): master = beat
        case .playing(let deck, let on): plays[deck] = on
        }
    }

    /// The readout's status for one deck. An upload still waiting for the unit's answer reads as not yet uploaded.
    public func status(deck: Int) -> JogUploadStatus {
        guard connected else { return .notConnected }
        guard let upload = uploads[deck], let accepted = upload.accepted else { return .notUploaded }
        return .uploaded(slot: upload.slot, bytes: upload.bytes, at: upload.at, accepted: accepted)
    }

    /// Whether the unit really shows this deck: connected, and the deck's upload is the latest. A preview (no
    /// LC6000, or the switch off) uploads only to itself, so it never counts (#318).
    public func onUnit(deck: Int) -> Bool { connected && front == deck }

    /// The words under a deck's preview (#318), literal for each case.
    public func card(deck: Int, timeZone: TimeZone = .current) -> String {
        guard connected else { return "Preview only: not on an LC6000" }
        guard front == deck, let upload = uploads[deck] else { return "Not on the LC6000 now" }
        guard let accepted = upload.accepted else { return "Sending to the LC6000" }
        return (accepted ? "Shown on the LC6000\n" : "Refused by the LC6000\n") + status(deck: deck).readout(timeZone: timeZone)
    }

    /// The deck's last needle pitch bend (0 until one arrives), for `JogNeedleAngle.degrees(pitchBend:)`.
    public func needle(deck: Int) -> Int { needles[deck] ?? 0 }

    /// Whether the deck is playing, as Syndicate reports it.
    public func playing(deck: Int) -> Bool { plays[deck] ?? false }

    /// The needle as the renderer takes it (#238): turns clockwise from 12 o'clock.
    public func needleTurns(deck: Int) -> Double { Double(needle(deck: deck)) / 16_384 }

    /// The beat section to light (1-4): the master clock's, the same on every deck, paused or not (#165, the user's
    /// pick). The needle is the deck's own phase, so the two together are a sync check. None before the clock runs.
    public func litBeat(deck: Int) -> Int? { master }
}

/// When a fast stream should hop to the window (#318): never while the window is closed (the state still updates,
/// off the main actor), once on opening, and while open at most one hop pending, which carries every change made
/// before it lands.
public struct VisibleFeed: Sendable {
    private var visible = false
    private var pending = false

    public init() {}

    /// The state changed: true to schedule a hop now.
    public mutating func changed() -> Bool {
        guard visible, !pending else { return false }
        pending = true
        return true
    }

    /// The hop landed: the window has the latest state.
    public mutating func published() { pending = false }

    /// The window opened or closed: true to hop once now, with the state as it is.
    public mutating func setVisible(_ on: Bool) -> Bool {
        visible = on
        return on ? changed() : false
    }
}
