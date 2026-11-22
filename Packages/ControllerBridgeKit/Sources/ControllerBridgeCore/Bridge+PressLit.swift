// The dark buttons (#476): buttons with no state to show are lit dim when idle, so the panel reads in the dark, and
// full while held, so every press shows. They're the bridge's own lights, not Syndicate's.

extension Bridge {
    /// Beat Jump, Track Skip, the browse knob's ring (its press), Vinyl, Pitch Bend and Param; and the deck select
    /// button (#477), which flashes full on the layer it steps to. A profile that doesn't name one has no light for it.
    static let pressLitButtons = ["beat_jump_back", "beat_jump_forward", "track_prev", "track_next", "select_press",
                                  "vinyl", "pitch_minus", "pitch_plus", "param_back", "param_forward", "deck_select"]

    /// Each one's light: full while held, else idle. Vinyl's is also full while its seek mode is on (#540).
    func pressLitLEDs() {
        for name in Self.pressLitButtons { buttonLED(name, on: pressLitOn(name)) }
    }

    private func pressLitOn(_ name: String) -> Bool {
        pressLitHeld.contains(name) || (name == "vinyl" && vinylSeek)
    }

    /// A press or release of a button: one of these lights full while it's held.
    func pressLit(_ name: String, _ pressed: Bool) {
        guard Self.pressLitButtons.contains(name) else { return }
        if pressed { pressLitHeld.insert(name) } else { pressLitHeld.remove(name) }
        buttonLED(name, on: pressLitOn(name))
    }
}
