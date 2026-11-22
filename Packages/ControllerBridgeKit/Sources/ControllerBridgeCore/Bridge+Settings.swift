// Settings changes (#19) that reach a running Bridge.

extension Bridge {
    /// Drives another Syndicate deck. Everything held is released on the old deck first, and what was known about the
    /// old deck is forgotten, so nothing from it shows on the new one. The caller resyncs.
    func switchDeck(to deck: Int) {
        releaseAll()
        mapping.deck.number = deck
        clearSyndicateState()
        // Feedback is still arriving; only the deck changed.
        feedbackStale = false
        reportedTempo = nil
        forgetMixerChannel()
        start()
        // The new deck's tempo comes with the answer to the resync's Resend; until then the fader waits.
        tempoWaitUntil = clock.now + Double(mapping.osc.feedbackAnswerMs) / 1000
    }
}

extension Bridge {
    /// A profile swap (#115) builds a new Bridge; it takes over what the old one knew of Syndicate's deck, so its
    /// first repaint already shows the deck, not idle until the Resend is answered. MIDI position memory isn't
    /// carried: the new profile may use other CCs.
    func carrySyndicateState(from old: Bridge) {
        playing = old.playing
        playPending = old.playPending
        lastPulseTime = old.lastPulseTime
        lastClockTime = old.lastClockTime
        loaded = old.loaded
        loadedHeard = old.loadedHeard
        synced = old.synced
        sliderEnabled = old.sliderEnabled
        looping = old.looping
        padModule.carryFeedback(from: old.padModule)
        jogModule.progressReported(old.jogModule.progress)
        duration = old.duration
        reportedTempo = old.reportedTempo
    }

    /// The bridge's own state (#115): Key Lock, Slip and the pad mode. Shift and held controls aren't carried: the
    /// swap released them.
    func carryOwnState(from old: Bridge) {
        keyLockOn = old.keyLockOn
        slipOn = old.slipOn
        padModule.carry(from: old.padModule)
    }
}
