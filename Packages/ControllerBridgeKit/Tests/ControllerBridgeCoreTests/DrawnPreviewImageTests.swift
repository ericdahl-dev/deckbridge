@testable import ControllerBridgeCore
import Testing

/// A deck's drawn state as the renderer's drawnImage takes it (#465): its content and its live values.
@Suite("Drawn display: the preview's image inputs")
struct DrawnPreviewImageTests {
    typealias Message = DrawnDisplay.Message

    static func state(_ messages: [Message]) -> DrawnDisplayState {
        var state = DrawnDisplayState()
        state.apply(Message.begin(version: 1).bytes)
        for message in messages { state.apply(message.bytes) }
        return state
    }

    @Test("A track: its deck, color, title, artist, key, tempo and player type, as the content")
    func track() throws {
        let state = Self.state([.deck(number: 2, color: [255, 0, 0], player: .track), .state([.loaded, .playing]),
                                .text(.title, "Café del Mar"), .text(.artist, "Energy 52"), .text(.key, "8A"),
                                .text(.untitled, ""), .tempo(tenths: 1245)])
        let content = try #require(state.preview(now: 0, timeAt: nil)).content
        #expect(content == JogDisplayContent(deck: 2, color: [255, 0, 0], title: "Café del Mar", artist: "Energy 52",
                                             key: "8A", bpm: 124.5, playerType: "track"))
    }

    @Test("No title: the untitled words as the player type, so the renderer says them; no tempo is nil")
    func untitled() throws {
        let midi = Self.state([.deck(number: 1, color: [0, 0, 255], player: .midiClip), .text(.title, ""),
                               .text(.untitled, "Midi clip"), .tempo(tenths: 0)])
        let content = try #require(midi.preview(now: 0, timeAt: nil)).content
        #expect(content.title == nil && content.bpm == nil && content.artist == nil && content.key == nil)
        #expect(JogDisplayWords.untitled(content.playerType).title == "Midi clip")
        let empty = Self.state([.deck(number: 1, color: [0, 0, 255], player: .empty), .text(.title, ""),
                                .text(.untitled, "No track")])
        #expect(try #require(empty.preview(now: 0, timeAt: nil)).content.playerType == "empty")
    }

    @Test("3 s with no message is the waiting look too (#569), as on the chip")
    func silence() throws {
        var state = DrawnDisplayState()
        for message: Message in [.begin(version: 1), .deck(number: 1, color: [0, 0, 255], player: .track), .state(.loaded)] {
            state.apply(message.bytes, atMs: 0)
        }
        state.tick(atMs: 2999)
        #expect(try #require(state.preview(now: 3, timeAt: nil)).content.stale == false)
        state.tick(atMs: 3000)
        #expect(try #require(state.preview(now: 3, timeAt: nil)).content.stale)
    }

    @Test("Stale feedback is the content's waiting look")
    func stale() throws {
        let state = Self.state([.deck(number: 1, color: [0, 0, 255], player: .track), .state([.loaded, .stale])])
        #expect(try #require(state.preview(now: 0, timeAt: nil)).content.stale)
    }

    @Test("The live values: beat, needle, meter, phase and time; no beat, and an unknown phase, are nil")
    func live() throws {
        let state = Self.state([.deck(number: 1, color: [0, 0, 255], player: .track), .beat(3), .needle(4096),
                                .meter(level: 64, peak: 90), .phase(-164), .time(elapsedSeconds: 65, lengthSeconds: 293)])
        let live = try #require(state.preview(now: 0, timeAt: 0)).live
        #expect(live == DrawnLive(beat: 3, needle: 4096, meter: .init(level: 64, peak: 90), phase: -164,
                                  time: .init(elapsed: 65, length: 293), look: .normal))
        let quiet = Self.state([.deck(number: 1, color: [0, 0, 255], player: .track), .beat(0)])
        let none = try #require(quiet.preview(now: 0, timeAt: nil)).live
        #expect(none.beat == nil && none.phase == nil && none.needle == nil && none.meter == nil && none.time == nil)
    }

    @Test("The last 30 s while playing blink off the time's arrival: red its first half second, then white")
    func look() throws {
        let state = Self.state([.deck(number: 1, color: [0, 0, 255], player: .track), .state([.loaded, .playing]),
                                .time(elapsedSeconds: 270, lengthSeconds: 293)])
        #expect(try #require(state.preview(now: 10.2, timeAt: 10)).live.look == .warningRed)
        #expect(try #require(state.preview(now: 10.7, timeAt: 10)).live.look == .warningWhite)
        #expect(try #require(state.preview(now: 11.1, timeAt: 10)).live.look == .warningRed)
    }

    @Test("60 s to 31 s left: steady red; a loop on (state bit 4) holds the warning (#524)")
    func steadyAndLoop() throws {
        let steady = Self.state([.deck(number: 1, color: [0, 0, 255], player: .track), .state([.loaded, .playing]),
                                 .time(elapsedSeconds: 250, lengthSeconds: 293)])
        #expect(try #require(steady.preview(now: 10.7, timeAt: 10)).live.look == .warningRed)
        let looping = Self.state([.deck(number: 1, color: [0, 0, 255], player: .track),
                                  .state([.loaded, .playing, .loopOn]), .time(elapsedSeconds: 270, lengthSeconds: 293)])
        #expect(try #require(looping.preview(now: 10.2, timeAt: 10)).live.look == .normal)
    }

    @Test("No deck yet: nothing to draw")
    func noDeck() {
        #expect(Self.state([]).preview(now: 0, timeAt: nil) == nil)
    }
}

/// The Diagnostics preview's drawn side (#465), as the view keeps it: each deck's state from the events, when its time
/// last changed, and whether the previews are drawn at all.
@Suite("Drawn display: the preview's model")
struct DrawnPreviewsTests {
    typealias Message = DrawnDisplay.Message

    static func state(deck: Int, _ messages: [Message]) -> DrawnDisplayState {
        DrawnPreviewImageTests.state([.deck(number: deck, color: [0, 0, 255], player: .track)] + messages)
    }

    @Test("Each deck's drawn preview draws until the previews go back to images; a deck never drawn has none")
    func drawnUntilEnded() {
        var previews = DrawnPreviews()
        previews.apply(.drawnPreview(Self.state(deck: 2, [.text(.title, "Strobe")])), at: 0)
        #expect(previews.image(deck: 2, now: 0)?.content.title == "Strobe")
        #expect(previews.image(deck: 1, now: 0) == nil)
        previews.apply(.drawnPreviewsEnded, at: 1)
        #expect(previews.image(deck: 2, now: 1) == nil)
    }

    @Test("The blink is timed off when the deck's time last changed, not off any other change")
    func timeAt() throws {
        var previews = DrawnPreviews()
        let playing: [Message] = [.state([.loaded, .playing]), .time(elapsedSeconds: 270, lengthSeconds: 293)]
        previews.apply(.drawnPreview(Self.state(deck: 1, playing)), at: 10)
        previews.apply(.drawnPreview(Self.state(deck: 1, playing + [.needle(4096)])), at: 10.6)
        #expect(previews.image(deck: 1, now: 10.7)?.live.look == .warningWhite)
        previews.apply(.drawnPreview(Self.state(deck: 1, [.state([.loaded, .playing]),
                                                         .time(elapsedSeconds: 271, lengthSeconds: 293)])), at: 10.8)
        #expect(previews.image(deck: 1, now: 10.9)?.live.look == .warningRed)
    }

    @Test("Other events change nothing")
    func otherEvents() {
        var previews = DrawnPreviews()
        previews.apply(.masterBeat(2), at: 0)
        previews.apply(.preview(JogDisplayContent(deck: 1, color: [0, 0, 255])), at: 0)
        #expect(previews.image(deck: 1, now: 0) == nil)
    }
}
