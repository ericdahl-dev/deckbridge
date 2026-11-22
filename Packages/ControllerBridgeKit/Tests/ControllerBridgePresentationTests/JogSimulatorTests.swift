import ControllerBridgePresentation
import Foundation
import Testing

/// The jog display simulator's words (#221), apart from the SwiftUI and the renderer.
@Suite("Jog display simulator")
struct JogSimulatorTests {
    @Test("VoiceOver hears each deck's display as one sentence: deck, title, key, BPM and beat")
    func spokenSummary() {
        #expect(JogDeckSummary(deck: 1, title: "Daybreak", key: "A#m", bpm: 128, beat: 2).spoken
            == "Deck 1, Daybreak, A#m, 128 BPM, beat 2")
        #expect(JogDeckSummary(deck: 3, title: "Night Drive", key: nil, bpm: 127.5, beat: nil).spoken
            == "Deck 3, Night Drive, 127.5 BPM")
        #expect(JogDeckSummary(deck: 2, title: nil, key: nil, bpm: nil, beat: nil).spoken == "Deck 2, no track loaded")
        #expect(JogDeckSummary(deck: 4, title: "", key: "C", bpm: 0, beat: 1).spoken == "Deck 4, no track loaded",
                "an empty title is an empty deck, as Syndicate sends it")
    }

    @Test("Each preview's readout: the slot, the size, when it was uploaded and the unit's answer; or why there's none")
    func readout() {
        let utc = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_763_294_671)  // 2025-11-16 12:04:31 UTC
        #expect(JogUploadStatus.uploaded(slot: 2, bytes: 14_812, at: noon, accepted: true).readout(timeZone: utc)
            == "Slot 2 · 14,812 bytes · 12:04:31 · Accepted")
        #expect(JogUploadStatus.uploaded(slot: 1, bytes: 980, at: noon, accepted: false).readout(timeZone: utc)
            == "Slot 1 · 980 bytes · 12:04:31 · Refused")
        #expect(JogUploadStatus.notUploaded.readout(timeZone: utc) == "Nothing uploaded yet")
        #expect(JogUploadStatus.notConnected.readout(timeZone: utc) == "No LC6000 connected: preview only")
    }

    @Test("The marker redraws at most 30 times a second, and a burst still ends on its latest value")
    func markerLimiter() {
        var limiter = RedrawLimiter<Int>(interval: 1.0 / 30)
        // The first value draws at once.
        #expect(limiter.offer(10, at: 0.000) == 10)
        // Within 1/30 s (0.0333…) nothing draws; the newest value waits.
        #expect(limiter.offer(11, at: 0.010) == nil)
        #expect(limiter.offer(12, at: 0.020) == nil)
        // The tick after the interval draws the waiting value, the newest one.
        #expect(limiter.tick(at: 0.030) == nil)
        #expect(limiter.tick(at: 0.034) == 12)
        // Nothing waiting: a tick draws nothing.
        #expect(limiter.tick(at: 0.100) == nil)
        // A value long after the last draw draws at once.
        #expect(limiter.offer(13, at: 0.200) == 13)
    }

    @Test("The marker's pitch bend is a fraction of a turn: 0 is 12 o'clock, 4096 a quarter turn clockwise (provisional, #165)")
    func markerAngle() {
        #expect(JogNeedleAngle.degrees(pitchBend: 0) == 0)
        #expect(JogNeedleAngle.degrees(pitchBend: 4096) == 90)
        #expect(JogNeedleAngle.degrees(pitchBend: 8192) == 180)
        #expect(JogNeedleAngle.degrees(pitchBend: 12288) == 270)
        #expect(JogNeedleAngle.degrees(pitchBend: 16383) == 359.978_027_343_75)
    }

    // The simulator's state from the display driver's events (#221), mapped by the App one to one.

    static let utc = TimeZone(identifier: "UTC")!
    @Test("The card's words say what really reached the unit (#318): a preview never reads On the LC6000")
    func cardWords() {
        var sim = JogSimulator()
        // Previewing (no LC6000, or the switch off): the driver still uploads to itself, so deck 1 is in front.
        sim.apply(.uploadStarted(slot: 1, deck: 1, bytes: 100, at: Self.noon))
        sim.apply(.shown(slot: 1))
        #expect(!sim.onUnit(deck: 1))
        #expect(sim.card(deck: 1, timeZone: Self.utc) == "Preview only: not on an LC6000")
        #expect(sim.card(deck: 3, timeZone: Self.utc) == "Preview only: not on an LC6000")

        sim.apply(.connected)
        sim.apply(.uploadStarted(slot: 2, deck: 1, bytes: 14_812, at: Self.noon))
        #expect(sim.onUnit(deck: 1))
        #expect(sim.card(deck: 1, timeZone: Self.utc) == "Sending to the LC6000")
        sim.apply(.shown(slot: 2))
        #expect(sim.card(deck: 1, timeZone: Self.utc) == "Shown on the LC6000\nSlot 2 · 14,812 bytes · 12:04:31 · Accepted")
        #expect(!sim.onUnit(deck: 3))
        #expect(sim.card(deck: 3, timeZone: Self.utc) == "Not on the LC6000 now")

        sim.apply(.uploadStarted(slot: 1, deck: 1, bytes: 980, at: Self.noon))
        sim.apply(.failed)
        #expect(sim.card(deck: 1, timeZone: Self.utc) == "Refused by the LC6000\nSlot 1 · 980 bytes · 12:04:31 · Refused")
    }

    @Test("Closed, the feed keeps the state but asks for no hop; opening asks once; open, one hop at a time (#318)")
    func visibleFeed() {
        var feed = VisibleFeed()
        var hops: [Bool] = []
        hops.append(feed.changed())            // Diagnostics closed: nothing to hop for
        hops.append(feed.changed())
        hops.append(feed.setVisible(true))     // opening publishes the latest once
        hops.append(feed.changed())            // that publish is still pending
        feed.published()
        hops.append(feed.changed())            // the next change hops
        hops.append(feed.changed())            // and the ones before it lands ride along
        feed.published()
        hops.append(feed.setVisible(false))
        hops.append(feed.changed())
        #expect(hops == [false, false, true, false, true, false, false, false])
    }

    static let noon = Date(timeIntervalSince1970: 1_763_294_671)  // 12:04:31 UTC

    @Test("Before the unit answers, every deck reads Not connected; once connected, Nothing uploaded yet")
    func connection() {
        var sim = JogSimulator()
        #expect(sim.status(deck: 1) == .notConnected)
        sim.apply(.connected)
        #expect(sim.status(deck: 1) == .notUploaded)
        sim.apply(.disconnected)
        #expect(sim.status(deck: 3) == .notConnected)
    }

    @Test("An upload the unit shows reads Accepted for its deck, which comes to the front; a refused one reads Refused")
    func uploads() {
        var sim = JogSimulator()
        sim.apply(.connected)
        sim.apply(.uploadStarted(slot: 2, deck: 1, bytes: 14_812, at: Self.noon))
        #expect(sim.front == 1)
        sim.apply(.shown(slot: 2))
        #expect(sim.status(deck: 1).readout(timeZone: Self.utc) == "Slot 2 · 14,812 bytes · 12:04:31 · Accepted")
        sim.apply(.uploadStarted(slot: 1, deck: 2, bytes: 980, at: Self.noon))
        sim.apply(.failed)
        #expect(sim.front == 2)
        #expect(sim.status(deck: 2).readout(timeZone: Self.utc) == "Slot 1 · 980 bytes · 12:04:31 · Refused")
        #expect(sim.status(deck: 1).readout(timeZone: Self.utc) == "Slot 2 · 14,812 bytes · 12:04:31 · Accepted")
    }

    @Test("Each deck has its own needle (the user's pick, #165) and its own play state, front or not (#317)")
    func needlesPerDeck() {
        var sim = JogSimulator()
        sim.apply(.connected)
        sim.apply(.uploadStarted(slot: 1, deck: 1, bytes: 100, at: Self.noon))
        sim.apply(.needle(deck: 1, pitchBend: 4096))
        sim.apply(.needle(deck: 3, pitchBend: 8192))
        sim.apply(.playing(deck: 3, true))
        #expect(sim.needle(deck: 1) == 4096)
        #expect(sim.needle(deck: 3) == 8192)
        #expect(!sim.playing(deck: 1))
        #expect(sim.playing(deck: 3))
        sim.apply(.playing(deck: 3, false))
        #expect(!sim.playing(deck: 3))
    }

    @Test("A deck with no needle yet sits at 12 o'clock")
    func noNeedleYet() {
        #expect(JogSimulator().needle(deck: 2) == 0)
    }

    @Test("The lit beat is the master's, the same on every deck, paused or not; none before the master clock runs")
    func masterBeat() {
        var sim = JogSimulator()
        #expect(sim.litBeat(deck: 1) == nil)
        sim.apply(.masterBeat(3))
        #expect([1, 2, 3, 4].map { sim.litBeat(deck: $0) } == [3, 3, 3, 3])
        sim.apply(.needle(deck: 1, pitchBend: 0))
        #expect(sim.litBeat(deck: 1) == 3, "the needle doesn't pick the segment")
        #expect(sim.needleTurns(deck: 3) == 0)
    }

    @Test("Diagnostics has a Jog display tab, last; before the unit shows anything it says how to turn it on")
    func tab() {
        #expect(DiagnosticsTab.allCases.map(\.rawValue) == ["MIDI Monitor", "LED Sweep", "OSC Log", "Jog display"])
        #expect(DiagnosticsTab.jog.emptyText(controllerConnected: true)
            == "Nothing on the jog display yet. Turn on Jog display in Settings, then load a track.")
        #expect(DiagnosticsTab.jog.emptyText(controllerConnected: false)
            == "No LC6000 connected. The jog display preview shows what DeckBridge sends it.")
    }
}
