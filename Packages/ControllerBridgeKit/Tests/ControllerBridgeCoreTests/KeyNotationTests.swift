import ControllerBridgeCore
import Testing

/// The key as the DJ wants to read it (#590): Syndicate sends traditional text whatever its own Camelot setting is.
@Suite("Key notation")
struct KeyNotationTests {
    /// Every key: its Camelot code, then the ways it may be written (sharp and flat spellings, `m`/`min`/`maj`,
    /// lower case, the Unicode accidentals). From the Camelot wheel, not from the code.
    static let wheel: [(camelot: String, traditional: String, spellings: [String])] = [
        ("1A", "G#m", ["G#m", "Abm", "g#m", "abm", "G#min", "Abmin", "A♭m", "G♯m"]),
        ("2A", "D#m", ["D#m", "Ebm", "d#min", "E♭m"]),
        ("3A", "A#m", ["A#m", "Bbm", "bbm", "B♭min", "A# minor"]),
        ("4A", "Fm", ["Fm", "fm", "Fmin", "F minor"]),
        ("5A", "Cm", ["Cm", "cm", "Cmin"]),
        ("6A", "Gm", ["Gm", "gmin"]),
        ("7A", "Dm", ["Dm", "dm"]),
        ("8A", "Am", ["Am", "am", "Amin"]),
        ("9A", "Em", ["Em", "em"]),
        ("10A", "Bm", ["Bm", "bm", "Bmin"]),
        ("11A", "F#m", ["F#m", "Gbm", "f#m", "G♭m"]),
        ("12A", "C#m", ["C#m", "Dbm", "c#min", "D♭m"]),
        ("1B", "B", ["B", "b", "Bmaj", "B major"]),
        ("2B", "F#", ["F#", "Gb", "F#maj", "gb", "G♭"]),
        ("3B", "C#", ["C#", "Db", "Dbmaj", "D♭"]),
        ("4B", "G#", ["G#", "Ab", "abmaj", "A♭"]),
        ("5B", "D#", ["D#", "Eb", "Ebmaj", "E♭"]),
        ("6B", "A#", ["A#", "Bb", "bb", "B♭maj"]),
        ("7B", "F", ["F", "f", "Fmaj"]),
        ("8B", "C", ["C", "c", "Cmaj", "C major"]),
        ("9B", "G", ["G", "Gmaj"]),
        ("10B", "D", ["D", "Dmaj"]),
        ("11B", "A", ["A", "Amaj"]),
        ("12B", "E", ["E", "Emaj"]),
    ]

    @Test("Camelot: all 24 keys, every spelling, give the wheel's code")
    func camelot() {
        #expect(Self.wheel.count == 24)
        #expect(Set(Self.wheel.map(\.camelot)).count == 24)
        for key in Self.wheel {
            for spelling in key.spellings {
                #expect(KeyNotation.camelot.shown(spelling) == key.camelot, "\(spelling)")
            }
        }
    }

    @Test("Traditional: the text as Syndicate sent it, unchanged")
    func traditional() {
        for key in Self.wheel {
            for spelling in key.spellings {
                #expect(KeyNotation.traditional.shown(spelling) == spelling, "\(spelling)")
            }
        }
    }

    @Test("A Camelot code from Syndicate: as is for Camelot, back to the traditional name for Traditional")
    func camelotInput() {
        for key in Self.wheel {
            for code in [key.camelot, key.camelot.lowercased(), "0" + key.camelot].filter({ $0.count <= 3 }) {
                #expect(KeyNotation.camelot.shown(code) == key.camelot, "\(code)")
                #expect(KeyNotation.traditional.shown(code) == key.traditional, "\(code)")
            }
        }
    }

    @Test("Text that isn't a key is shown unchanged", arguments: ["", "—", "-", "?", "H", "C##", "13A", "0A", "Cmx",
                                                                  "Fb", "track", " "])
    func unrecognized(text: String) {
        #expect(KeyNotation.camelot.shown(text) == text)
        #expect(KeyNotation.traditional.shown(text) == text)
    }
}
