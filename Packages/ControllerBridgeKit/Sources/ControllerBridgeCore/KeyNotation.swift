import Foundation

/// How the jog display and its preview write a track's key (#590). Syndicate sends the key as traditional text
/// (`C#m`, `A#m`) whatever its own Camelot setting is, and reports that setting nowhere, so the DJ picks here.
public enum KeyNotation: String, Equatable, Sendable, Codable, CaseIterable {
    /// The text as Syndicate sends it.
    case traditional
    /// The Camelot wheel's code: `C#m` is `12A`, `E` is `12B`.
    case camelot

    /// The key text to show. Text that isn't a key (empty, a dash, anything else) is shown as it is. A Camelot code
    /// from Syndicate is shown as is for Camelot, and as its traditional name (sharps) for Traditional.
    public func shown(_ text: String) -> String {
        if let (number, minor) = Self.camelotCode(text) {
            switch self {
            case .camelot: return "\(number)\(minor ? "A" : "B")"
            case .traditional:
                let major = ((number - 8 + 12) % 12) * 7 % 12
                return Self.sharpNames[minor ? (major + 9) % 12 : major] + (minor ? "m" : "")
            }
        }
        guard self == .camelot, let (pitch, minor) = Self.traditionalKey(text) else { return text }
        // The major key with the same code: the minor key's relative major, three semitones up.
        let major = minor ? (pitch + 3) % 12 : pitch
        return "\((major * 7 % 12 + 7) % 12 + 1)\(minor ? "A" : "B")"
    }

    private static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    /// The usual spellings only: no E#, B#, Cb or Fb.
    private static let pitches: [String: Int] = [
        "c": 0, "c#": 1, "db": 1, "d": 2, "d#": 3, "eb": 3, "e": 4, "f": 5, "f#": 6, "gb": 6, "g": 7, "g#": 8, "ab": 8,
        "a": 9, "a#": 10, "bb": 10, "b": 11,
    ]

    /// `1A`…`12B`, any case, a leading zero allowed: the number and whether it's minor (A).
    private static func camelotCode(_ text: String) -> (Int, Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = trimmed.last, letter == "A" || letter == "B",
              let number = Int(trimmed.dropLast()), (1...12).contains(number),
              trimmed.dropLast().allSatisfy(\.isASCII), trimmed.dropLast().allSatisfy(\.isNumber) else { return nil }
        return (number, letter == "A")
    }

    /// A note name, an optional accidental, then nothing or a major or minor word: the pitch (C = 0) and whether it's
    /// minor.
    private static func traditionalKey(_ text: String) -> (Int, Bool)? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b"))
        guard let first = rest.first, "abcdefg".contains(first) else { return nil }
        var name = String(rest.removeFirst())
        if let accidental = rest.first, accidental == "#" || accidental == "b" {
            name.append(rest.removeFirst())
        }
        guard let pitch = pitches[name] else { return nil }
        switch rest.replacingOccurrences(of: " ", with: "") {
        case "", "maj", "major": return (pitch, false)
        case "m", "min", "minor": return (pitch, true)
        default: return nil
        }
    }
}
