// Continuous controls: the pitch fader, the jog wheel and the Needle Drop strip.

extension Bridge {
    func pitchMSB(_ value: UInt8) {
        pitchMSBValue = value
        sendPitch()
    }

    func pitchLSB(_ value: UInt8) {
        pitchLSBValue = value
        sendPitch()
    }

    /// The tempo the fader's position stands for, rounded as it's sent.
    func faderTempo(_ pitch: Mapping.Pitch) -> Double {
        // A 7-bit fader is one CC (#195); the LC6000's is an MSB/LSB pair.
        let t = pitch.bits == 7
            ? tempoSlider(from7Bit: pitchMSBValue, invert: pitch.invert, deadZone: pitch.deadZone)
            : tempoSlider(from: join14Bit(msb: pitchMSBValue, lsb: pitchLSBValue), invert: pitch.invert, deadZone: pitch.deadZone)
        return (t * 100_000).rounded() / 100_000
    }

    private func sendPitch() {
        guard let pitch = mapping.pitch else { return }
        faderKnown = true
        // The arrows follow every move, whether or not it drives the tempo (#475).
        defer { pitchArrowLEDs() }
        let rounded = faderTempo(pitch)
        // Moving the fader while Syndicate has the slider disabled would queue up a jump.
        guard sliderEnabled, pickedUp(at: rounded) else { return }
        guard rounded != lastTempo else { return }
        lastTempo = rounded
        recentTempoSends.removeAll { clock.now - $0.time > Self.echoWindow }
        recentTempoSends.append((clock.now, rounded))
        sendDeck("TempoSlider", .float(Float(rounded)))
        refreshLEDs()
    }

    // MARK: Pickup

    /// Sets Syndicate's tempo slider to 0.0, then waits for the fader to come back to 0.0 so it doesn't jump the tempo
    /// back to where the fader sits (#114). A synced follower's slider is disabled, and Syndicate ignores TempoSlider
    /// then, so nothing is sent.
    func resetTempo() {
        guard sliderEnabled else { return }
        rearmPickup()
        reportedTempo = 0
        tempoWaitUntil = nil
        // Syndicate's answer is the echo of this send, not an outside change.
        recentTempoSends.removeAll { clock.now - $0.time > Self.echoWindow }
        recentTempoSends.append((clock.now, 0))
        sendDeck("TempoSlider", .float(0))
        refreshLEDs()
    }

    /// How long after a send its echo may still come back from Syndicate.
    static let echoWindow = 0.5

    /// Syndicate reported its TempoSlider. A value the bridge didn't send (sync, a mouse edit, another controller)
    /// moved the on-screen slider away from the fader, so pickup re-arms.
    func tempoReported(_ value: Double) {
        reportedTempo = value
        tempoWaitUntil = nil
        let tolerance = mapping.pitch?.pickupTolerance ?? 0
        let isEcho = lastTempo.map { abs($0 - value) <= tolerance } == true
            || recentTempoSends.contains { clock.now - $0.time <= Self.echoWindow && abs($0.value - value) <= tolerance }
        if !isEcho { rearmPickup() }
    }

    /// Dim while the fader waits to be picked up, so it can be caught by feel; otherwise full at the center.
    var pitchCenterVelocity: UInt8 {
        if mapping.pitch?.pickup == true, pickupArmed, reportedTempo != nil { return dimLevel }
        return lastTempo == 0 ? fullLevel : offLevel
    }

    /// The shared fader's raw position from the layer that had it (#475), if that one knew it.
    func takeFader(from other: Bridge) {
        guard other.faderKnown else { return }
        pitchMSBValue = other.pitchMSBValue
        pitchLSBValue = other.pitchLSBValue
        faderKnown = true
    }

    /// The pitch arrows (#475): during pickup, the one pointing the way to move the fader is full, the other off.
    /// Back is toward a lower raw value, forward toward a higher one, whatever `invert` says. Both are off when the
    /// fader's within the catch tolerance, its position isn't known yet, or there's nothing to catch.
    func pitchArrowLEDs() {
        var back = offLevel, forward = offLevel
        if let pitch = mapping.pitch, pitch.pickup, pickupArmed, sliderEnabled, loaded, faderKnown, let reported = reportedTempo {
            let gap = faderTempo(pitch) - reported
            if abs(gap) > pitch.pickupTolerance {
                // Below the value in tempo is below it in raw terms, unless the fader's inverted.
                if (gap < 0) != pitch.invert { forward = fullLevel } else { back = fullLevel }
            }
        }
        if let note = mapping.leds.pitchArrowBack { led(note, back) }
        if let note = mapping.leds.pitchArrowForward { led(note, forward) }
    }

    func rearmPickup() {
        pickupArmed = true
        faderPosition = nil
        // Syndicate's slider may be anywhere now, so the pickup send goes out even if it repeats the last value.
        lastTempo = nil
    }

    /// Whether the fader at `position` drives the tempo. While armed it doesn't, until it comes within tolerance of
    /// the reported value or moves across it. With no report yet there is nothing to meet, so the fader passes
    /// through, except just after a deck switch, when it waits for the new deck's report (`tempoWaitUntil`).
    private func pickedUp(at position: Double) -> Bool {
        guard let pitch = mapping.pitch, pitch.pickup, pickupArmed else { return true }
        guard let reported = reportedTempo else {
            if let until = tempoWaitUntil, clock.now < until { return false }
            return true
        }
        let previous = faderPosition
        faderPosition = position
        let near = abs(position - reported) <= pitch.pickupTolerance
        let crossed = previous.map { ($0 - reported) * (position - reported) < 0 } ?? false
        guard near || crossed else { return false }
        pickupArmed = false
        return true
    }

    // MARK: Jog and Needle Drop (#383: JogModule)

    func needleMSB(_ value: UInt8) { jogModule.needleMSB(value) }

    func needleLSB(_ value: UInt8) {
        guard let needle = mapping.needle else { return }
        if stripFader.touching {
            if let move = stripFader.position(jogModule.needlePosition(lsb: value)) {
                send(address: MixerOSC.address(.volume, channel: move.channel, root: root), [.float(Float(move.level))])
            }
            return
        }
        applyJog(jogModule.needleLSB(value, needle: needle, playing: playing, now: clock.now))
    }

    /// How a plain touch on the strip moves the channel fader (#609, the plain layer since #729), or nil when it seeks:
    /// Settings' choice, else the profile's. Read at touch-down, so a change applies from the next touch.
    var stripFaderMode: Mapping.Needle.ShiftFaderMode? {
        guard let shown = stripFaderSetting.shown(for: mapping.needle), shown.enabled else { return nil }
        return shown.mode
    }

    /// Without Shift at touch-down, the touch moves the deck's channel fader until it lifts (#609, #729); with Shift it
    /// seeks (needle drop), and with the fader off every touch seeks. Every touch-down picks afresh, so a lost touch-up
    /// can't leave the strip a fader.
    func needleTouch(_ pressed: Bool) {
        if pressed { stripFader.touchUp() }
        if pressed, !shift, let mode = stripFaderMode {
            stripFader.touchDown(channel: mapping.deck.number, mode: mode)
            return
        }
        if !pressed, stripFader.touching {
            stripFader.touchUp()
            return
        }
        applyJog(jogModule.needleTouch(pressed))
    }

    func jogMSB(_ value: UInt8) { jogModule.jogMSB(value) }

    func jogLSB(_ value: UInt8) {
        guard let wheel = mapping.jog else { return }
        applyJog(jogModule.jogLSB(value, wheel: wheel, playing: jogBends, musicMoving: playing, duration: duration,
                                  now: clock.now))
    }

    /// A relative jog's tick on the platter's top (#204), in the profile's encoder format.
    func jogRelative(_ value: UInt8) { jogTicks(mapping.midi.encoderFormat.ticks(value), needsTouch: true) }

    /// A relative jog's tick on the platter's edge (#204): it moves without a touch.
    func jogRelativeEdge(_ value: UInt8) { jogTicks(mapping.midi.encoderFormat.ticks(value), needsTouch: false) }

    private func jogTicks(_ counts: Int, needsTouch: Bool) {
        guard let wheel = mapping.jog else { return }
        applyJog(jogModule.jog(counts: counts, needsTouch: needsTouch, wheel: wheel, playing: jogBends, musicMoving: playing,
                               duration: duration, now: clock.now))
    }

    /// Whether the jog bends: a playing deck, unless VINYL's seek mode is on (#540); otherwise it seeks.
    private var jogBends: Bool { playing && !vinylSeek }

    /// VINYL (#540) toggles the playing jog between bending and seeking. A bend under way ends.
    func vinyl(_ pressed: Bool) {
        guard pressed else { return }
        vinylSeek.toggle()
        if vinylSeek { applyJog(jogModule.playingChanged(false)) }
    }

    func platterTouch(_ pressed: Bool) { applyJog(jogModule.platterTouch(pressed)) }

    /// Sends what the jog module asks: OSC to this deck, the bend as a held PhaseBend, and quantize holds through the
    /// Bridge's one QuantizeOverride.
    func applyJog(_ sends: [JogModule.Send]) {
        for send in sends {
            switch send {
            case .osc(let path, let argument): sendDeck(path, argument)
            case .hold(let reason): overrideQuantize(reason)
            case .release(let reason): restoreQuantize(reason)
            case .bend(let direction): hold(.bend, "PhaseBend", press: [.int(Int32(direction))], release: [.int(0)])
            case .endBend: releaseHold(.bend)
            }
        }
    }

    func tick() {
        // The bend ends first and the seek's quantize goes back last, as before the module (#383).
        let jogSends = jogModule.tick(now: clock.now, wheel: mapping.jog)
        applyJog(jogSends.filter { $0 == .endBend })
        timingTick()
        meterTick()
        applyCues(cueMemory.tick(now: clock.now))
        applyJog(jogSends.filter { $0 != .endBend })
    }
}
