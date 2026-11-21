@testable import ControllerBridgeCore
import Foundation
@testable import SyndicateDeck
import Testing

/// Slice 2 (#680): the tool sends what DeckBridge itself sends for the same buttons, so a test run drives Syndicate as
/// a DJ on the controller would.
@Suite("Syndicate deck: the messages")
struct MessagesTests {
    final class Recorded: OSCSender, @unchecked Sendable {
        var sent: [OSCMessage] = []
        func send(_ message: OSCMessage) { sent.append(message) }
    }

    struct StillClock: Clock { let now = 100.0 }

    /// DeckBridge's own Bridge on deck 1, the bundled LC6000 profile, recording what it sends.
    static func bridge() throws -> (Bridge, Recorded) {
        let osc = Recorded()
        let mapping = try Mapping.bundledDefault()
        #expect(mapping.deck.number == 1)
        return (Bridge(mapping: mapping, osc: osc, clock: StillClock()), osc)
    }

    @Test func toggleIsThePlayButton() throws {
        let (bridge, osc) = try Self.bridge()
        bridge.play(true)
        #expect(Deck.messages(for: .toggle(deck: 1)) == osc.sent)
    }

    @Test func playFromAHotCueIsThePadsPressAndReleaseThenPlaying() throws {
        let (bridge, osc) = try Self.bridge()
        bridge.handlePad(2, pressed: true)  // the third pad: hot cue 3
        bridge.handlePad(2, pressed: false)
        let pad = osc.sent.filter { $0.address.hasSuffix("/HotCue") }
        #expect(pad.count == 2)
        // Play while Cue is held sets Playing 1 (#360): the app's own way to start a deck without toggling it.
        osc.sent.removeAll()
        bridge.cue(true)
        osc.sent.removeAll()
        bridge.play(true)
        #expect(Deck.messages(for: .play(deck: 1, cue: 3)) == pad + osc.sent)
        #expect(Deck.messages(for: .play(deck: 1, cue: nil)) == osc.sent)
    }

    /// Pause sets Playing 0, as the cue module does: never a toggle, so pausing twice never starts the deck.
    @Test func pauseIsPlaying0OnTheWire() {
        let bytes = Deck.messages(for: .pause(deck: 3)).map { $0.encoded() }
        // "/Syndicate/Deck/3/Playing" (25 bytes, padded to 28), ",i" padded to 4, then 0, big-endian. By hand.
        let address = Array("/Syndicate/Deck/3/Playing".utf8) + [0, 0, 0]
        #expect(bytes == [address + [0x2C, 0x69, 0, 0] + [0, 0, 0, 0]])
    }

    @Test func theDeckNumberIsTheOneAsked() {
        #expect(Deck.messages(for: .toggle(deck: 4)).map(\.address) == ["/Syndicate/Deck/4/PlayPause"])
        #expect(Deck.messages(for: .play(deck: 2, cue: 8)).map(\.address)
                == ["/Syndicate/Deck/2/HotCue", "/Syndicate/Deck/2/HotCue", "/Syndicate/Deck/2/Playing"])
    }
}
