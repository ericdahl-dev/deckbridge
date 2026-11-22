import Foundation
@testable import ControllerBridgeCore
import Testing

/// #585, the owner: "sometimes when stopped, the track moves forward no matter if I turn the platter backwards or
/// forwards". The trace (deck 4, 20:32 UTC) pairs it: on a paused deck Syndicate reports Progress about 0.1 s AHEAD of
/// each WaveformSeek (0.00034 of that track), about 100 times a second, while the jog seeks about 200 times a second.
/// A backward turn's seeks alternated: −0.00004 from the hand, then +0.00034 when the next report came in.
@Suite("Paused jog: Syndicate's position reports")
struct PausedJogFeedbackTests {
    typealias Q = JogQuantizeTests

    static func seeks(_ rig: Rig) -> [Float] {
        rig.osc.sent.filter { $0.address.hasSuffix("/WaveformSeek") }.compactMap { if case .float(let f) = $0.arguments.first { f } else { nil } }
    }

    /// A paused deck (200 s, halfway, 1000 counts and 4 s a turn) turned slowly backward, 2 counts a message (0.00004 of
    /// the track) every 5 ms, with Syndicate answering every other seek with Progress 0.0003 ahead of it, as the trace
    /// shows.
    static func backwardTurnWithReportsAhead() throws -> Rig {
        let rig = try Q.paused()
        var platter = 2000
        for step in 0..<40 {
            rig.clock.now = 10 + Double(step) * 0.005
            platter -= 2
            ContinuousTests.platterAt(rig, platter)
            if step % 2 == 1, let last = seeks(rig).last {
                ContinuousTests.feedback(rig, "Progress", [.float(last + 0.0003)])
            }
        }
        return rig
    }

    @Test("A backward turn moves the track backward, even with Syndicate's reports running ahead of the seeks")
    func backwardStaysBackward() throws {
        let sent = Self.seeks(try Self.backwardTurnWithReportsAhead())
        #expect(sent.count == 40)
        // The owner's symptom: it ended up AHEAD of where it started. 80 counts back is 0.32 s: 0.0016 back from halfway.
        #expect(sent.last! < 0.5)
        #expect(abs(Double(sent.last!) - 0.4984) < 0.00005)
        // No seek goes forward during a backward turn.
        #expect(zip(sent, sent.dropFirst()).allSatisfy { $1 <= $0 })
    }

    @Test("A jump under the hand is followed: a report more than 1 s of track from the jog's own place (a cue, a load)")
    func farReportFollowed() throws {
        let rig = try Q.paused()
        rig.clock.now = 10
        ContinuousTests.platterAt(rig, 1990)
        // A hot cue mid-turn: Syndicate is now at 0.25 (50 s off, far more than 1 s).
        ContinuousTests.feedback(rig, "Progress", [.float(0.25)])
        rig.clock.now = 10.005
        ContinuousTests.platterAt(rig, 1980)
        // From the cue: 10 counts back is 0.04 s, 0.0002.
        #expect(abs(Double(Self.seeks(rig).last!) - 0.2498) < 0.00001)
    }

    @Test("Once the hand has stopped (the hold released after 0.3 s), Syndicate's reports count again")
    func reportsAfterTheHold() throws {
        let rig = try Q.paused()
        rig.clock.now = 10
        ContinuousTests.platterAt(rig, 1990)
        rig.clock.now = 10.4
        rig.coordinator.tick()   // the hold is released
        ContinuousTests.feedback(rig, "Progress", [.float(0.6)])
        rig.clock.now = 10.5
        ContinuousTests.platterAt(rig, 1980)
        #expect(abs(Double(Self.seeks(rig).last!) - 0.5998) < 0.00001)
    }

    /// #547's VINYL seek on a playing deck reuses the paused step, so it had the same ratchet: there the reports also
    /// move at play speed. While the hand moves, the jog's own place runs on with the music (1 s a second) instead.
    @Test("VINYL on a playing deck: a slow backward turn with reports 0.1 s ahead moves with the music minus the hand, not ahead")
    func vinylPlayingNoRatchet() throws {
        let rig = try VinylSeekTests.playing()
        VinylSeekTests.vinyl(rig)
        rig.osc.sent.removeAll()
        var platter = 2000
        for step in 0..<40 {
            rig.clock.now = 10 + Double(step) * 0.005
            platter -= 2
            ContinuousTests.platterAt(rig, platter)
            if step % 2 == 1, let last = Self.seeks(rig).last {
                // Playing: Syndicate's place is the seek plus the time since, and 0.1 s of lead (0.0005 of 200 s).
                ContinuousTests.feedback(rig, "Progress", [.float(last + 0.0005 + 0.005 / 200)])
            }
        }
        // 0.195 s of music (0.000975) less the hand's 78 counts after the first (0.312 s, 0.00156): about 0.49942.
        #expect(abs(Double(Self.seeks(rig).last!) - 0.49942) < 0.0001)
    }
}
