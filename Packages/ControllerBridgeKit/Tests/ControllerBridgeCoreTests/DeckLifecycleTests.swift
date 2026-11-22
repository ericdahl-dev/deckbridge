@testable import ControllerBridgeCore
import Testing

/// One deck-lifecycle path (#383): every way a deck's moment ends (a new track, Play, releasing everything, which
/// unplug, quit, a deck switch and a profile swap go through) runs `Bridge.end(_:)`, which drops a pending cue jump and
/// puts every quantize hold back, whatever took it.
@Suite("Deck lifecycle")
struct DeckLifecycleTests {
    static let quantizeGlobal = OSCMessage("/Syndicate/Deck/1/Quantize", [.int(0)])
    static let reasons: [QuantizeOverride.Reason] = [.cueJump, .jogSeek, .returnToCue]

    static func bridge() throws -> (Bridge, Rig.FakeOSC) {
        let osc = Rig.FakeOSC()
        return (Bridge(mapping: try Mapping.bundledDefault(), osc: osc, clock: Rig.FakeClock()), osc)
    }

    @Test("Every exit puts back every hold, alone or together: one Use Global, nothing left held", arguments: DeckExit.allCases)
    func noHoldLeaks(_ exit: DeckExit) throws {
        let holds: [[QuantizeOverride.Reason]] = Self.reasons.map { [$0] } + [Self.reasons]
        for held in holds {
            let (bridge, osc) = try Self.bridge()
            for reason in held { bridge.overrideQuantize(reason) }
            osc.sent.removeAll()
            bridge.end(exit)
            #expect(osc.sent.filter { $0.address.hasSuffix("/Quantize") } == [Self.quantizeGlobal], "\(exit) after \(held)")
            #expect(!bridge.quantizeOverride.isHeld, "\(exit) after \(held)")
        }
    }

    @Test("Nothing held: no Quantize sent", arguments: DeckExit.allCases)
    func nothingHeld(_ exit: DeckExit) throws {
        let (bridge, osc) = try Self.bridge()
        bridge.end(exit)
        #expect(!osc.sent.contains { $0.address.hasSuffix("/Quantize") })
    }

    @Test("A cue jump waiting for its launch is dropped by every exit", arguments: DeckExit.allCases)
    func cueJumpDropped(_ exit: DeckExit) throws {
        let (bridge, _) = try Self.bridge()
        bridge.goToCuePaused(1)
        #expect(bridge.cueMemory.isJumpPending)
        bridge.end(exit)
        #expect(!bridge.cueMemory.isJumpPending)
    }
}
