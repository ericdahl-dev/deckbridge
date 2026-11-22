// Browse, loop and jump controls (#16), as in the Python bridge.

extension Bridge {
    // MARK: Browser

    func trackPrevious(_ pressed: Bool) {
        if pressed { send("Browser/Up", .int(1)) }
    }

    func trackNext(_ pressed: Bool) {
        if pressed { send("Browser/Down", .int(1)) }
    }

    func browserBack(_ pressed: Bool) {
        if pressed { send("Browser/Back", .int(1)) }
    }

    func browserForward(_ pressed: Bool) {
        if pressed { send("Browser/Enter", .int(1)) }
    }

    func selectPress(_ pressed: Bool) {
        if pressed { send(shift ? "Browser/Enter" : "Browser/L\(mapping.deck.number)", .int(1)) }
    }

    /// Syndicate's per-deck waveform zoom triggers (#479), read from its app's input names; the argument is the one
    /// its other triggers take. A live check with Syndicate confirms both.
    static let zoomIn = "WaveformZoomIn", zoomOut = "WaveformZoomOut", zoomArgument: OSCArgument = .int(1)

    /// One browser step per tick. With Shift (printed ZOOM, #479), one zoom of the deck in front per tick instead:
    /// in clockwise, out counter-clockwise.
    func selectTurn(_ value: UInt8) {
        let ticks = mapping.midi.encoderFormat.ticks(value)
        for _ in 0..<abs(ticks) {
            if shift { sendDeck(ticks > 0 ? Self.zoomIn : Self.zoomOut, Self.zoomArgument) }
            else { send(ticks > 0 ? "Browser/Down" : "Browser/Up", .int(1)) }
        }
    }

    // MARK: Loops

    func loopIn(_ pressed: Bool) {
        if pressed { sendDeck("LoopIn", .int(1)) }
    }

    func loopOut(_ pressed: Bool) {
        if pressed { sendDeck("LoopOut", .int(1)) }
    }

    func autoLoop(_ pressed: Bool) {
        if pressed { sendDeck("Loop", .int(1)) }
    }

    /// While looping, Syndicate's LoopOut doubles the loop and LoopIn halves it. One step per turn, however fast.
    /// With Shift held it's the knob's printed Loop Move (#470): each click moves the loop by its own length, forward
    /// clockwise. With no loop reported, nothing is sent.
    func autoLoopSize(_ value: UInt8) {
        let ticks = mapping.midi.encoderFormat.ticks(value)
        guard ticks != 0 else { return }
        if shift {
            guard let beats = loopBeats else { return }
            for _ in 0..<abs(ticks) { sendDeck("LoopMoveBeat", .int(Int32(ticks > 0 ? beats : -beats))) }
        } else {
            sendDeck(ticks > 0 ? "LoopOut" : "LoopIn", .int(1))
        }
    }

    /// The reported loop's length in whole beats, at the deck's tempo: the nearest of 1, 2, 4 … 64, so a tempo that's
    /// a little off still lands on the loop's size. A loop under a beat counts as 1. Nil with no loop or no tempo.
    var loopBeats: Int? {
        guard let loopSeconds, let bpm else { return nil }
        let beats = loopSeconds * bpm / 60
        return [1, 2, 4, 8, 16, 32, 64].min { abs(Double($0) - beats) < abs(Double($1) - beats) }
    }

    // MARK: Jumps

    func beatJumpBack(_ pressed: Bool) {
        if pressed { sendDeck(shift ? "SkipBarBack" : "SkipBeatBack", .int(1)) }
    }

    func beatJumpForward(_ pressed: Bool) {
        if pressed { sendDeck(shift ? "SkipBarForward" : "SkipBeatForward", .int(1)) }
    }

    func paramBack(_ pressed: Bool) {
        if pressed { sendDeck("BeatSkip", .int(-1)) }
    }

    func paramForward(_ pressed: Bool) {
        if pressed { sendDeck("BeatSkip", .int(1)) }
    }

    // MARK: LEDs

    /// The three loop buttons light together while Syndicate reports a loop.
    func loopLEDs() {
        for name in ["loop_in", "loop_out", "auto_loop"] { buttonLED(name, on: looping) }
    }
}
