@testable import ControllerBridgeCore
import Testing

/// The Bridge's cue memory as its own module (#383): the Shift + pad jump to a hot cue on a stopped deck (#358, #363)
/// and the main cue point Shift + CUE goes back to (#360). Both learn where cues are from Syndicate's Position, which
/// never reports cue times. Plain values in, sends out; the Bridge applies them.
@Suite("Cue module")
struct CueModuleTests {
    typealias Send = CueModule.Send

    @Test("Shift + pad, unlearned: quantize held, Cue2 tapped; Syndicate plays: Playing 0, quantize back; the first Position, less 0.06, is cue 2")
    func jumpLearns() {
        var cues = CueModule()
        #expect(cues.shiftPad(2, duration: 200, now: 0) == [.hold(.cueJump), .osc("Cue2", .int(1))])
        #expect(cues.isJumpPending)
        #expect(cues.playingChanged(true, now: 0.1) == [.osc("Playing", .int(0)), .release(.cueJump)])
        cues.positionReported(30.02, playing: true, now: 0.11)
        #expect(cues.shiftPad(2, duration: 200, now: 1) == [.hold(.cueJump), .osc("WaveformSeek", .float(Float(29.96 / 200))), .release(.cueJump)])
    }

    @Test("A second Shift + pad before the launch drops the jump; so does the 4 s timeout, on the tick")
    func jumpDropped() {
        var cues = CueModule()
        _ = cues.shiftPad(1, duration: 200, now: 0)
        #expect(cues.shiftPad(1, duration: 200, now: 0.2) == [.release(.cueJump)])
        _ = cues.shiftPad(1, duration: 200, now: 1)
        #expect(cues.tick(now: 5) == [])
        #expect(cues.tick(now: 5.01) == [.release(.cueJump)])
        #expect(!cues.isJumpPending)
    }

    @Test("A launch after the timeout isn't the pad's: dropped, not paused")
    func lateLaunch() {
        var cues = CueModule()
        _ = cues.shiftPad(1, duration: 200, now: 0)
        #expect(cues.playingChanged(true, now: 4.5) == [.release(.cueJump)])
    }

    @Test("Main cue: CUE while paused at 30 s remembers 30; Shift + CUE from 52 s seeks there with quantize None")
    func mainCuePaused() {
        var cues = CueModule()
        cues.positionReported(30, playing: false, now: 0)
        cues.cuePressed(playing: false, now: 0)
        cues.positionReported(52, playing: false, now: 1)
        #expect(cues.shiftCue(duration: 200) == [.hold(.returnToCue), .osc("WaveformSeek", .float(0.15)), .release(.returnToCue)])
    }

    @Test("Main cue: CUE while playing remembers where the deck stops, within 0.5 s, from the stop or the Position after")
    func mainCuePlaying() {
        var cues = CueModule()
        cues.positionReported(40, playing: true, now: 0)
        cues.cuePressed(playing: true, now: 0)
        cues.positionReported(30, playing: false, now: 0.1)
        cues.positionReported(52, playing: false, now: 2)
        #expect(cues.shiftCue(duration: 200) == [.hold(.returnToCue), .osc("WaveformSeek", .float(0.15)), .release(.returnToCue)])

        var late = CueModule()
        late.positionReported(40, playing: true, now: 0)
        late.cuePressed(playing: true, now: 0)
        late.positionReported(30, playing: false, now: 0.6)
        #expect(late.shiftCue(duration: 200) == [], "too late to be the CUE's stop")
    }

    @Test("Shift + CUE: unknown, or on the cue point already, sends nothing")
    func shiftCueNothing() {
        var cues = CueModule()
        cues.positionReported(52, playing: false, now: 0)
        #expect(cues.shiftCue(duration: 200) == [])
        cues.cuePressed(playing: false, now: 0)
        #expect(cues.shiftCue(duration: 200) == [])
    }

    @Test("A new track forgets every cue time and the main cue point, and drops a pending jump")
    func forget() {
        var cues = CueModule()
        cues.positionReported(30, playing: false, now: 0)
        cues.cuePressed(playing: false, now: 0)
        _ = cues.shiftPad(1, duration: 200, now: 0)
        #expect(cues.forgetTrack() == [.release(.cueJump)])
        cues.positionReported(52, playing: false, now: 1)
        #expect(cues.shiftCue(duration: 200) == [])
        #expect(!cues.isJumpPending)
    }
}
