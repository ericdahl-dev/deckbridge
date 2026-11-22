@testable import ControllerBridgeCore
import Testing

/// What the chip knows, decoded from the drawn messages in Swift (#465), as dfw.c decodes them: the Diagnostics
/// preview draws from it, so it shows what the chip got.
@Suite("Drawn display: the chip's state, in Swift")
struct DrawnDisplayStateTests {
    typealias Vectors = DrawnDisplayVectorsTests
    static let begin = DrawnDisplay.Message.begin(version: 1).bytes
    static let deck3 = DrawnDisplay.Message.deck(number: 3, color: [0, 255, 0], player: .sequencer).bytes

    static func codes(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }

    @Test("Every host message in the shared vectors decodes to its fields, after begin and a deck")
    func vectors() {
        let entries = (Vectors.file["messages"] as! [[String: Any]]).filter { $0["direction"] as? String != "unit" }
        for entry in entries {
            let name = entry["name"] as! String, fields = entry["fields"] as! [String: Any]
            var state = DrawnDisplayState()
            state.apply(Self.begin)
            state.apply(Self.deck3)
            state.apply(Vectors.bytes(entry))
            switch entry["kind"] as! String {
            case "capability", "begin", "end": continue
            case "deck":
                #expect(state.deck == DrawnDisplayState.Deck(number: fields["number"] as! Int, color: fields["color"] as! [Int],
                                                             player: DrawnDisplay.Player(rawValue: UInt8(fields["player"] as! Int))!),
                        "\(name)")
            case "state": #expect(state.flags.rawValue == UInt8(fields["flags"] as! Int), "\(name)")
            case "beat": #expect(state.beat == fields["beat"] as! Int, "\(name)")
            case "needle": #expect(state.needle == fields["angle"] as? Int, "\(name)")
            case "meter":
                #expect(state.meter?.level == fields["level"] as? Int && state.meter?.peak == fields["peak"] as? Int, "\(name)")
            case "text":
                let field = DrawnDisplay.TextField(rawValue: UInt8(fields["field"] as! Int))!
                #expect(state.texts[field] == Self.codes(fields["codes"] as? String ?? ""), "\(name)")
            case "tempo": #expect(state.tempo == fields["tenths"] as! Int, "\(name)")
            case "phase": #expect(state.phase == fields["offset"] as! Int, "\(name)")
            case "time":
                #expect(state.time?.elapsed == fields["elapsed"] as? Int && state.time?.length == fields["length"] as? Int,
                        "\(name)")
            default: Issue.record("\(name): a kind the state doesn't decode")
            }
        }
    }

    @Test("A deck change or end forgets the time (#460), as the chip does")
    func timeCleared() {
        var state = DrawnDisplayState()
        state.apply(Self.begin)
        state.apply(Self.deck3)
        state.apply(DrawnDisplay.Message.time(elapsedSeconds: 65, lengthSeconds: 293).bytes)
        #expect(state.time?.elapsed == 65)
        state.apply(DrawnDisplay.Message.deck(number: 1, color: [255, 0, 0], player: .track).bytes)
        #expect(state.time == nil)
        state.apply(DrawnDisplay.Message.time(elapsedSeconds: 65, lengthSeconds: 293).bytes)
        state.apply(DrawnDisplay.Message.end(version: 1).bytes)
        #expect(state.time == nil)
    }

    @Test("Every invalid host message in the shared vectors changes nothing, as on the chip")
    func invalid() {
        let bad = (Vectors.file["invalid"] as! [[String: Any]]).filter { $0["direction"] as? String != "unit" }
        #expect(!bad.isEmpty)
        for entry in bad {
            var state = DrawnDisplayState()
            state.apply(Self.begin)
            state.apply(Self.deck3)
            state.apply(DrawnDisplay.Message.state(.loaded).bytes)
            let before = state
            let changed = state.apply(Vectors.bytes(entry))
            #expect(!changed, "\(entry["name"]!)")
            #expect(state == before, "\(entry["name"]!)")
        }
    }

    typealias Message = DrawnDisplay.Message

    /// Begin, deck 3, then its state, texts, tempo, phase and the live values, as the full state sends them.
    static func full() -> DrawnDisplayState {
        var state = DrawnDisplayState()
        for message: Message in [.begin(version: 1), .deck(number: 3, color: [0, 255, 0], player: .sequencer),
                                 .state([.loaded, .playing, .stale]), .text(.title, "Strobe"), .tempo(tenths: 1280),
                                 .phase(164), .beat(2), .needle(4096), .meter(level: 64, peak: 90)] {
            state.apply(message.bytes)
        }
        return state
    }

    @Test("Nothing before begin: a deck, text or state message alone is ignored")
    func beforeBegin() {
        var state = DrawnDisplayState()
        for message: Message in [.deck(number: 3, color: [0, 255, 0], player: .sequencer), .text(.title, "Strobe"),
                                 .state(.loaded), .phase(164)] {
            state.apply(message.bytes)
        }
        #expect(state == DrawnDisplayState())
    }

    @Test("The heartbeat's same deck changes nothing; another deck clears flags 0-4, texts, tempo and phase, keeps stale")
    func deckChange() {
        var state = Self.full()
        let changed = state.apply(Message.deck(number: 3, color: [0, 255, 0], player: .sequencer).bytes)
        #expect(!changed)
        #expect(state.texts[.title] == Array("Strobe".utf8) && state.tempo == 1280 && state.phase == 164)
        state.apply(Message.deck(number: 1, color: [255, 0, 0], player: .track).bytes)
        #expect(state.flags == .stale)
        #expect(state.texts.isEmpty && !state.textHeard && state.tempo == 0 && state.phase == DrawnPhase.unknown)
        // The master clock's beat, the needle and the meter aren't the deck's: they stay.
        #expect(state.beat == 2 && state.needle == 4096 && state.meter?.level == 64)
    }

    @Test("End forgets the deck and everything live; a new begin starts from nothing")
    func end() {
        var state = Self.full()
        state.apply(Message.end(version: 1).bytes)
        state.apply(Message.begin(version: 1).bytes)
        #expect(state.drawn)
        #expect(state.deck == nil && state.flags == [] && state.beat == 0 && state.needle == nil)
        #expect(state.meter == nil && state.phase == DrawnPhase.unknown)
    }
}
