// The deck number's ink on its deck color: the chip's number and, on the drawn display, the stale logo's hub. Black
// reads on most deck colors; on a dark one it vanishes, so it turns white there. The display firmware's C keeps the
// same rule.
import Foundation

public enum DeckNumberInk {
    /// Below this relative luminance white contrasts more than black (WCAG: (L + 0.05)² = 0.05 × 1.05).
    public static let threshold = JogLayout.numberWhiteBelow

    /// White on `color` ([r, g, b], 0-255): its relative luminance under `threshold`.
    public static func white(on color: [Int]) -> Bool {
        guard color.count == 3 else { return false }
        func linear(_ channel: Int) -> Double {
            let c = Double(min(max(channel, 0), 255)) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color[0]) + 0.7152 * linear(color[1]) + 0.0722 * linear(color[2])
        return luminance < threshold
    }
}
