/// The ways a deck's moment ends (#383). Unplug, quit, sleep, a deck switch, a device change and a profile swap all
/// release everything, so they come through `.releaseAll`.
enum DeckExit: CaseIterable, Sendable {
    case newTrack
    case play
    case releaseAll
}

extension Bridge {
    /// The one deck-lifecycle path (#383): a cue jump still waiting for its launch is dropped, and every quantize hold
    /// goes back to Use Global, once, whatever took it. Every exit calls this; nothing else releases holds wholesale.
    func end(_ exit: DeckExit) {
        applyCues(cueMemory.endJump())
        restoreAllQuantize()
    }
}
