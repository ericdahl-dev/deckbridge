// Timing LEDs (#23): the pending-start blink and the beat pulse. Driven by tick, through the de-duplicating LED cache.

extension Bridge {
    /// How long the Play LED stays on, then off, while a start is pending.
    static let blinkHalfPeriod = 0.25
    /// With no master clock beat for this long (one beat at 30 BPM), the ring goes back to solid.
    static let clockTimeout = 2.0

    func timingTick() {
        colorTick()
        playLED()
        ringLED()
    }

    /// Full while playing. While a quantized start is pending, it blinks on the clock.
    func playLED() {
        let blinkOn = Int((clock.now / Self.blinkHalfPeriod).rounded(.down)) % 2 == 0
        buttonLED("play", on: playing || (playPending && blinkOn))
    }

    /// Syndicate's master clock (not this deck's own beat): beat-in-bar 1-4 on every master beat.
    func headerClock(_ arguments: [OSCArgument]) {
        lastClockTime = clock.now
        switch mapping.leds.beatPulse {
        case .off: return
        case .beat: break
        case .downbeat: guard arguments.first?.wholeNumber == 1 else { return }
        }
        lastPulseTime = clock.now
        // A beat goes out at once, whatever the pacing.
        nextPulseSend = nil
        ringLED()
    }

    /// Syndicate's master BPM: the smooth pulse's beat length (#533).
    func headerBPM(_ arguments: [OSCArgument]) {
        if let bpm = arguments.first?.number, bpm > 0 { masterBPM = bpm }
    }

    /// The smooth pulse's messages a second, at most (#533): one constant, to lower after the unit's check.
    static let pulseRate = 30.0
    /// The smooth pulse rests at this part of full between beats, never dark (the user's pick).
    static let pulseRest = 0.25

    /// The smooth pulse's level now, 0.25-1, or nil when it isn't pulsing: full on the beat, easing down to the rest by
    /// the next one (25% + 75% × (1 − p)², p the part of the beat gone, the beat from the master BPM, 120 if unknown).
    var pulseLevel: Double? {
        guard mapping.leds.beatPulse != .off, let pulse = lastPulseTime, let beat = lastClockTime,
              clock.now - beat <= Self.clockTimeout else { return nil }
        let beats = mapping.leds.beatPulse == .downbeat ? 4.0 : 1.0
        let length = beats * 60 / (masterBPM ?? 120)
        let gone = min(max((clock.now - pulse) / length, 0), 1)
        return Self.pulseRest + (1 - Self.pulseRest) * (1 - gone) * (1 - gone)
    }

    /// Lit while a track is loaded. With beat pulse on and a clock arriving, lit only for `pulse_ms` after each beat.
    func ringLED() {
        // With the color message, the pulse fades in the deck's exact hue (#533), paced to pulseRate.
        if let encoder = colorMessageEncoder, let level = pulseLevel {
            let on = loaded && !ringHeld
            if on, let due = nextPulseSend, clock.now < due - 1e-9 { return }
            let rgb = on ? ringColor.map { Int(Double($0) * level) } : [0, 0, 0]
            guard let message = encoder.message(note: mapping.leds.ring, rgb: rgb) else { return }
            if on { nextPulseSend = clock.now + 1 / Self.pulseRate }
            return colorLED(message)
        }
        var lit = loaded
        if let pulse = lastPulseTime, let beat = lastClockTime, clock.now - beat <= Self.clockTimeout {
            lit = lit && clock.now - pulse < Double(mapping.leds.pulseMs) / 1000
        }
        let on = lit && !ringHeld
        if let message = colorMessageEncoder?.message(note: mapping.leds.ring, rgb: on ? ringColor : [0, 0, 0]) {
            return colorLED(message)
        }
        led(mapping.leds.ring, on ? ringVelocity(ringColor) : Self.off)
    }

    /// Settings (#530): the color message on or off; the ring and pads repaint.
    func setColorMessages(_ on: Bool) {
        guard on != colorMessages else { return }
        colorMessages = on
        // From scratch: on the unit, a color message and a note-on each replace what the other showed.
        repaintLEDs()
    }

    /// Settings (#532): the color-message LEDs' brightness; the pads and ring whose color changes are sent again.
    func setLightBrightness(_ percent: Int) {
        guard percent != lightBrightness else { return }
        lightBrightness = percent
        refreshLEDs()
    }

    /// Vivid or exact (#151): the ring and pads repaint.
    func setRingColors(_ mode: RingColors) {
        ringColors = mode
        refreshLEDs()
    }

    /// New deck colors (#123): the ring repaints in its deck's.
    func setDeckColors(_ colors: DeckColors) {
        deckColors = colors
        ringLED()
    }

    /// The deck's badge color, so the ring shows which deck this layer drives (#122).
    var ringColor: [Int] {
        guard mapping.leds.ringFollowsDeck, let deck = deckColors[mapping.deck.number] else { return mapping.leds.ringColor }
        return deck
    }
}
