import Foundation
@testable import ControllerBridgeCore
import Testing

/// "Quantize None while X, restore Use Global after" (#366), shared by the Shift + cue jump (#363), the paused jog's
/// seeks (#366) and return to cue (#360): Syndicate quantizes seeks and launches with Q on, and doesn't report a
/// deck's quantize, so DeckBridge turns it off while it needs it off and back to Use Global after.
@Suite("Quantize override")
struct QuantizeOverrideTests {
    @Test("The first reason in turns it off; the last one out puts it back; overlapping reasons never send twice")
    func overlapping() {
        var q = QuantizeOverride()
        var sends: [String] = []
        func note(_ change: QuantizeOverride.Change?) { if let change { sends.append(change == .none ? "None" : "Global") } }
        note(q.acquire(.cueJump))
        note(q.acquire(.jogSeek))
        note(q.acquire(.jogSeek))           // again: already held
        note(q.release(.cueJump))           // jog still holds it
        note(q.release(.cueJump))           // not held: nothing
        note(q.release(.jogSeek))           // last out
        note(q.release(.jogSeek))
        #expect(sends == ["None", "Global"])
        #expect(!q.isHeld)
    }

    @Test("Release all puts it back once, only if something held it")
    func releaseAll() {
        var q = QuantizeOverride()
        #expect(q.releaseAll() == nil)
        _ = q.acquire(.returnToCue)
        _ = q.acquire(.jogSeek)
        #expect(q.releaseAll() == .useGlobal)
        #expect(q.releaseAll() == nil)
        #expect(!q.holds(.jogSeek))
    }
}
