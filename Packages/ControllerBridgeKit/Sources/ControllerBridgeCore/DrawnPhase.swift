// The drawn display's phase rule (#462): a deck's PhaseOffset as the value op 0B carries.

/// One deck's phase value for the wire.
struct DrawnPhase {
    /// Op 0B's unknown: not playing, or no offset since the deck loaded.
    static let unknown = -8192
    /// In phase is entered under `enter` beats and left only over `leave`, so the tick doesn't flicker at the edge.
    static let enter = 0.002, leave = 0.004

    /// Past `wrap` beats, an offset on the other side from the last shown is the deck drifting through ±½ (where
    /// Syndicate's offset jumps sides): the last side holds, as a full bar, until the offset is back under `wrap`.
    static let wrap = 0.4

    private var inPhase = false
    /// The side of the last offset shown off phase: -1 behind, 1 ahead.
    private var side: Int?

    /// The last value `value` gave, for the preview (#465).
    private(set) var lastValue = DrawnPhase.unknown

    /// The value to send for the deck's latest offset in beats.
    mutating func value(offset: Double?, playing: Bool) -> Int {
        lastValue = next(offset: offset, playing: playing)
        return lastValue
    }

    private mutating func next(offset: Double?, playing: Bool) -> Int {
        guard playing, let offset, offset.isFinite else {
            inPhase = false
            side = nil
            return Self.unknown
        }
        inPhase = inPhase ? abs(offset) <= Self.leave : abs(offset) < Self.enter
        if inPhase { return 0 }
        let sign = offset < 0 ? -1 : 1
        if let side, side != sign, abs(offset) > Self.wrap { return side * 8191 }
        side = sign
        return Int(min(max((offset * 16384).rounded(), -8191), 8191))
    }
}
