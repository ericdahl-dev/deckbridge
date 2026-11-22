/// Syndicate's deck colors, as the app's deck badges draw them (#34). The platter ring shows its deck's color (#122).
///
/// One source of truth: the Presentation tests pin `DeckBadge`'s fills to `defaults`. A value, so a user setting can
/// replace the defaults later (#123): the Bridge reads its colors from its own `deckColors`.
/// How the ring (and a held pad) turns a color into the LC6000's 64 (#151): vivid keeps the hue; exact rounds each
/// channel, as the pad cue colors do.
public enum RingColors: String, Equatable, Sendable, Codable, CaseIterable {
    case vivid, exact
}

/// The LC6000's jog display firmware (#425), the DJ's pick in Settings: Denon's own, or one flashed with the slot 16
/// patch (tools/lc6000-firmware). Denon's is the default, and the only safe choice for a unit that wasn't flashed.
public enum DisplayFirmware: String, Equatable, Sendable, Codable, CaseIterable {
    case denon, custom

    /// How many image slots the firmware will show.
    public var showableSlots: Int { self == .custom ? 16 : 15 }
}

public struct DeckColors: Equatable, Sendable, Codable {
    /// [r, g, b] for decks 1-4.
    public var rgb: [Int: [Int]]

    public init(rgb: [Int: [Int]]) {
        self.rgb = rgb
    }

    /// Saved as four [r, g, b] arrays, deck 1 first.
    public init(from decoder: any Decoder) throws {
        let list = try decoder.singleValueContainer().decode([[Int]].self)
        rgb = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.offset + 1, $0.element) })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode((1...4).map { rgb[$0] ?? [0, 0, 0] })
    }

    /// [r, g, b] for a deck, or nil for a deck outside 1-4.
    public subscript(deck: Int) -> [Int]? { rgb[deck] }

    /// The color as the controller shows it, for Settings' preview swatch: the ring's velocity through a color table
    /// (#197), read back as RGB. Settings' swatch is labeled "On the LC6000", so it passes rgb222 (#313).
    public static func ledPreview(_ rgb: [Int], mode: RingColors = .exact, table: ColorTable = .rgb222) -> [Int] {
        guard rgb.count == 3 else { return [0, 0, 0] }
        return table.shown(mode == .vivid ? table.vivid(for: rgb) : table.velocity(for: rgb))
    }

    /// Whether the color is black, the one color the LC6000's ring can't show.
    public static func isBlack(_ rgb: some Collection<Int>) -> Bool { rgb.allSatisfy { $0 == 0 } }

    /// Before Syndicate's palette arrives: its factory deck colors, cue palette slots 1, 3, 5 and 7 of the same
    /// factory table the pads use (red, yellow, cyan, purple).
    public static let defaults = DeckColors(rgb: Dictionary(uniqueKeysWithValues: (1...4).map {
        ($0, PadModule.defaultPalette[2 * $0 - 1] ?? [0, 0, 0])
    }))

    /// The deck whose color a cue palette slot holds: slots 1, 3, 5 and 7 are decks 1-4 (#123). Nil for any other.
    public static func deck(forSlot slot: Int) -> Int? {
        slot % 2 == 1 && (1...7).contains(slot) ? (slot + 1) / 2 : nil
    }

    /// After a ColorPalette message ([slot, r, g, b]): the deck whose slot it is (slot 2N−1 is deck N) takes the color.
    /// Nil when the message isn't a deck's slot, so nothing needs repainting.
    public func updated(byPalette numbers: [Int]) -> DeckColors? {
        guard numbers.count >= 4, let deck = Self.deck(forSlot: numbers[0]) else { return nil }
        var out = self
        // Black would turn the ring off: that deck keeps its default color.
        out.rgb[deck] = Self.isBlack(numbers[1...3]) ? Self.defaults[deck] : Array(numbers[1...3])
        return out == self ? nil : out
    }
}
