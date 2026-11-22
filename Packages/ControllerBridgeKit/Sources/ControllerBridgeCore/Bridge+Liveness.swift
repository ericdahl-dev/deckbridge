// Feedback liveness (#21): what a Bridge forgets when Syndicate's feedback stops.

extension Bridge {
    /// The button LEDs that show Syndicate's state, not the bridge's own.
    static let syndicateButtons: Set<String> = ["play", "cue", "sync", "master", "loop_in", "loop_out", "auto_loop"]

    /// Forgets everything learned from Syndicate's feedback, so its LEDs show idle, not a track that may be gone.
    /// The bridge's own state (Shift, Key Lock, Slip, the pad mode, held controls) stays.
    func clearSyndicateState() {
        playing = false
        playPending = false
        loaded = false
        synced = false
        sliderEnabled = true
        looping = false
        padModule.clearCues(count: 8)
        jogModule.progressReported(nil)
        duration = nil
        bpm = nil
        lastPulseTime = nil
        lastClockTime = nil
        feedbackStale = true
        refreshLEDs()
    }
}
