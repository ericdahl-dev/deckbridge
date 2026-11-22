@testable import ControllerBridgeCore
import Testing

/// What a Bridge knows of its Syndicate deck, as one read-only value (#383): the only way the Coordinator, the jog
/// display (#384) and the Bridge's own modules read it.
@Suite("Deck facts")
struct DeckFactsTests {
    static func feed(_ bridge: Bridge, _ name: String, _ arguments: [OSCArgument]) {
        bridge.handle(OSCMessage("/Syndicate/Deck/1/" + name, arguments))
    }

    @Test("Empty until Syndicate says otherwise")
    func empty() throws {
        let (bridge, _) = try DeckLifecycleTests.bridge()
        #expect(bridge.facts == DeckFacts(deck: 1))
    }

    @Test("Built from the deck's feedback: loaded, playing, BPM, the track, its length, where it is, and the bar phase")
    func fromFeedback() throws {
        let (bridge, _) = try DeckLifecycleTests.bridge()
        Self.feed(bridge, "Loaded", [.int(1)])
        Self.feed(bridge, "Playing", [.int(1)])
        Self.feed(bridge, "BPM", [.float(124)])
        Self.feed(bridge, "TrackInfo", [.string("Song, Part 2"), .string("Artist"), .string("8A"), .float(123.5), .float(200),
                                        .int(100), .int(400), .string("track")])
        Self.feed(bridge, "Position", [.float(30.5)])
        Self.feed(bridge, "BarRamp", [.float(0.25)])
        #expect(bridge.facts == DeckFacts(
            deck: 1, playing: true, loaded: true, loadedHeard: true, bpm: 124,
            track: DeckFacts.Track(title: "Song, Part 2", artist: "Artist", key: "8A", bpm: 123.5, playerType: "track"),
            duration: 200, position: 30.5, barRamp: DeckFacts.BarRamp(phase: 0.25, at: 0)
        ))
    }

    @Test("Another deck's feedback isn't this deck's")
    func otherDeck() throws {
        let (bridge, _) = try DeckLifecycleTests.bridge()
        bridge.handle(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        bridge.handle(OSCMessage("/Syndicate/Deck/2/BarRamp", [.float(0.5)]))
        #expect(bridge.facts == DeckFacts(deck: 1))
    }

    @Test("PhaseOffset (#462): the deck's beat offset from the master, negative behind, kept until the next; an unload forgets it")
    func phaseOffset() throws {
        let (bridge, _) = try DeckLifecycleTests.bridge()
        Self.feed(bridge, "Loaded", [.int(1)])
        Self.feed(bridge, "PhaseOffset", [.float(-0.04)])
        #expect(bridge.facts.phaseOffset.map { abs($0 + 0.04) < 1e-6 } == true)
        Self.feed(bridge, "Loaded", [.int(0)])
        #expect(bridge.facts.phaseOffset == nil)
    }
}
