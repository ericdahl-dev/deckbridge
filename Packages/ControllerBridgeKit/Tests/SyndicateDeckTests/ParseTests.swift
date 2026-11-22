@testable import SyndicateDeck
import Testing

/// Slice 1 (#680): the command line, as an agent or the owner types it.
@Suite("Syndicate deck: the command line")
struct ParseTests {
    @Test func playFromAHotCue() throws {
        let call = try Call.parse(["play", "1", "--cue", "3"])
        #expect(call.command == .play(deck: 1, cue: 3))
        #expect(call.host == nil && call.port == nil)
    }

    @Test func playWithoutACue() throws {
        #expect(try Call.parse(["play", "2"]).command == .play(deck: 2, cue: nil))
    }

    @Test func pauseAndToggle() throws {
        #expect(try Call.parse(["pause", "4"]).command == .pause(deck: 4))
        #expect(try Call.parse(["toggle", "1"]).command == .toggle(deck: 1))
    }

    @Test func hostAndPortOverTheSettings() throws {
        let call = try Call.parse(["pause", "1", "--host", "192.168.1.20", "--port", "9091"])
        #expect(call.host == "192.168.1.20")
        #expect(call.port == 9091)
    }

    /// Syndicate has decks 1-4 and 8 hot cues a deck; anything else is a typing slip, said before anything is sent.
    @Test func outOfRangeOrUnknownIsAUsageError() {
        for bad in [[], ["play"], ["play", "5"], ["play", "0"], ["play", "1", "--cue", "9"], ["play", "1", "--cue"],
                    ["stop", "1"], ["pause", "x"], ["pause", "1", "--port", "70000"], ["pause", "1", "extra"]] {
            #expect(throws: UsageError.self, "\(bad)") { try Call.parse(bad) }
        }
    }
}
