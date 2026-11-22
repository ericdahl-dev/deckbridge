/// What the jog display says about a deck's player type (#209), shared by the image renderer and the drawn display's
/// untitled-words text (#458), so the two screens say the same.
public enum JogDisplayWords {
    /// The badge for Syndicate's player type: TRK for a track, OSC, MIDI or SEQ for a clip of that kind (#209).
    public static func badge(_ playerType: String?) -> String? {
        guard let type = playerType?.lowercased(), !type.isEmpty, type != "empty" else { return nil }
        if type == "track" { return "TRK" }
        for (needle, label) in [("osc", "OSC"), ("midi", "MIDI"), ("seq", "SEQ")] where type.contains(needle) { return label }
        return String(type.uppercased().prefix(4))
    }

    /// What a deck with no title shows: "OSC clip" for an OSC clip, the player type's own name for another kind (an
    /// Automation deck says "Automation"), "No track" when it's empty.
    public static func untitled(_ playerType: String?) -> (title: String, caption: String) {
        guard let label = badge(playerType), label != "TRK", let playerType else { return ("No track", "Load a track") }
        if label == "OSC" { return ("OSC clip", "no title") }
        return (playerType.prefix(1).uppercased() + playerType.dropFirst().lowercased(), "no title")
    }
}
