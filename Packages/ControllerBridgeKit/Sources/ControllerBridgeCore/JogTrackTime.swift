// Track time on the drawn jog display (#460, #524): how the last minute's warning looks now. The renderer draws it; the
// display firmware's C keeps the same rules.

public enum JogTrackTime {
    /// Steady red from this many seconds left.
    public static let warningSeconds = DrawnDisplayProtocol.warningSeconds
    /// Blinking from this many seconds left.
    public static let blinkSeconds = DrawnDisplayProtocol.blinkSeconds
    /// The warning's red, 0xFF3B30.
    public static let warningRed = channels(JogLayout.warningRed)
    /// The blink's other color, the text's white, 0xEDEDEA, whatever the deck color.
    public static let warningWhite = channels(JogLayout.warningWhite)

    /// 0xRRGGBB as [r, g, b].
    static func channels(_ hex: Int) -> [Int] { [hex >> 16 & 0xFF, hex >> 8 & 0xFF, hex & 0xFF] }

    public enum Look: Equatable, Sendable {
        /// No warning: the text white, the ring the deck color.
        case normal
        /// Steady red, or the blink's red half: text and ring fill red.
        case warningRed
        /// The blink's white half: text and ring fill white.
        case warningWhite
    }

    /// Playing, not looping (a loop holds the warning) and a known length: steady red with `warningSeconds` or less left; with `blinkSeconds` or less, a
    /// 1 Hz blink. `phase` is the time since the shown second last changed (0 to 1), so red starts on the frame the
    /// digit changes.
    public static func look(elapsed: Int, length: Int, playing: Bool, looping: Bool, phase: Double) -> Look {
        guard playing, !looping, length > 0 else { return .normal }
        let left = length - elapsed
        guard left <= warningSeconds else { return .normal }
        return left <= blinkSeconds && phase >= 0.5 ? .warningWhite : .warningRed
    }
}
