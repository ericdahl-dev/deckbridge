// Transport buttons: Play, Cue, Sync, Master, Censor, Key Lock, Slip, Pitch Bend − / + and Shift.
// Triggers fire on press only; holds send 1, then 0.

extension Bridge {
    func play(_ pressed: Bool) {
        // Play wins over a Shift + pad tap still waiting to be paused (#358).
        guard pressed else { return }
        end(.play)
        // PLAY while CUE is held keeps the preview playing once CUE is let go, as on a CDJ (#360): set, not toggled,
        // and Syndicate never gets the Cue release, which would take it back to the cue point (the user's test).
        if cueDown {
            _ = held.take(.cue)
            return sendDeck("Playing", .int(1))
        }
        sendDeck("PlayPause", .int(1))
    }

    /// Sync toggles the deck's sync. With Shift (#478, printed OFF) it only turns sync off: from a synced deck the
    /// toggle goes, otherwise nothing, so it never turns sync on.
    func sync(_ pressed: Bool) {
        guard pressed, !shift || synced else { return }
        sendDeck("TempoSync", .int(1))
    }

    func master(_ pressed: Bool) {
        if pressed { sendDeck("TempoMaster", .int(1)) }
    }

    /// Pitch Bend − (#114): nudges the tempo down while held. With Shift, it transposes down a semitone (#377).
    func pitchMinus(_ pressed: Bool) {
        if shift { transpose("PitchDown", pressed) } else { holdButton(.phaseMinus, "PhaseMinus", pressed: pressed) }
    }

    /// Pitch Bend + (#114): nudges the tempo up while held. With Shift, it transposes up a semitone (#377).
    func pitchPlus(_ pressed: Bool) {
        if shift { transpose("PitchUp", pressed) } else { holdButton(.phasePlus, "PhasePlus", pressed: pressed) }
    }

    /// Shift + Pitch Bend: Syndicate's PitchDown / PitchUp triggers, one semitone per press (User Guide 14.6). Syndicate
    /// applies them only with the deck's P (key lock) on, so key lock goes on first, every press: it may have been
    /// turned off in Syndicate itself, which DeckBridge doesn't hear (the user's pick, #377).
    private func transpose(_ address: String, _ pressed: Bool) {
        guard pressed else { return }
        keyLockOn = true
        sendDeck("PitchPreserve", .int(1))
        sendDeck(address, .int(1))
        refreshLEDs()
    }

    func shiftButton(_ pressed: Bool) {
        shift = pressed
        refreshLEDs()
    }

    /// Key Lock toggles key lock; Shift + Key Lock is the LC6000's pitch reset, sent as a tempo reset (#114).
    func keyLock(_ pressed: Bool) {
        guard pressed else { return }
        if shift { return resetTempo() }
        keyLockOn.toggle()
        sendDeck("PitchPreserve", .int(keyLockOn ? 1 : 0))
        refreshLEDs()
    }

    func slip(_ pressed: Bool) {
        guard pressed else { return }
        slipOn.toggle()
        sendDeck("CueSlip", .int(slipOn ? 1 : 0))
        refreshLEDs()
    }

    /// CUE is Syndicate's own: back to the cue point and stop while playing, preview while held on it, and a new cue
    /// point when paused elsewhere. Shift + CUE goes back to the cue point and stops (#360), and never sets one.
    func cue(_ pressed: Bool) {
        if pressed, shift {
            shiftCueDown = true
            if playing { return holdButton(.cue, "Cue", pressed: true) }
            return applyCues(cueMemory.shiftCue(duration: duration))
        }
        if !pressed, shiftCueDown {
            shiftCueDown = false
            return holdButton(.cue, "Cue", pressed: false)
        }
        cueDown = pressed
        if pressed {
            // Syndicate's cue point is where it's paused, or, while playing, where it stops.
            cueMemory.cuePressed(playing: playing, now: clock.now)
        }
        holdButton(.cue, "Cue", pressed: pressed)
    }

    /// Censor reverses while held. Shift + Censor latches Reverse instead: each press toggles it (#114). A latched
    /// Reverse isn't a hold, but release-all still turns it off.
    func censor(_ pressed: Bool) {
        // Its light shows reverse on, held or latched (#477).
        defer { refreshLEDs() }
        if pressed, shift {
            if let address = latchedReverse {
                send(address: address, [.int(0)])
                latchedReverse = nil
            } else {
                let address = deckAddress("Reverse")
                send(address: address, [.int(1)])
                latchedReverse = address
            }
            return
        }
        guard pressed || held.contains(.censor) else { return }
        holdButton(.censor, "Reverse", pressed: pressed)
        // The hold's release turned Reverse off in Syndicate, latched or not.
        if !pressed { latchedReverse = nil }
    }

    // MARK: Holds

    /// A hold whose press sends 1 and whose release sends 0.
    func holdButton(_ key: HoldKey, _ path: String, pressed: Bool) {
        if pressed {
            hold(key, path, press: [.int(1)], release: [.int(0)])
        } else {
            releaseHold(key)
        }
    }

    /// Sends the press, and records the release with this deck's full address.
    func hold(_ key: HoldKey, _ path: String, press: [OSCArgument], release: [OSCArgument]) {
        let address = deckAddress(path)
        send(address: address, press)
        held.record(key, HeldControl(deck: mapping.deck.number, address: address, release: release))
    }

    /// Sends every recorded release once, then forgets them. Quit, unplug, sleep, a deck or device change and a
    /// mapping import all come through here.
    func releaseAll() {
        // Censor's light (#477) goes back to idle with the reverse it showed, held or latched.
        let reversed = reverseOn
        defer { if reversed { refreshLEDs() } }
        end(.releaseAll)
        for control in held.takeAll() { send(address: control.address, control.release) }
        if let address = latchedReverse {
            send(address: address, [.int(0)])
            latchedReverse = nil
        }
        jogModule.releaseAll()
        stripFader.touchUp()
        cueDown = false
        shiftCueDown = false
        if shift {
            shift = false
            refreshLEDs()
        }
    }

    func releaseHold(_ key: HoldKey) {
        guard let control = held.take(key) else { return }
        send(address: control.address, control.release)
    }
}

// MARK: LEDs

extension Bridge {
    /// The deck is Syndicate's tempo master: synced, with its tempo slider enabled. The Master LED and the status share it.
    var isMaster: Bool { synced && sliderEnabled }

    /// The transport LEDs: Cue, Sync and Master follow Syndicate; Key Lock, Slip and Shift show the bridge's state.
    func refreshTransportLEDs() {
        buttonLED("cue", on: loaded && !playing)
        buttonLED("sync", on: synced)
        buttonLED("master", on: isMaster)
        buttonLED("key_lock", on: keyLockOn)
        buttonLED("slip", on: slipOn)
        buttonLED("shift", on: shift)
        buttonLED("censor", on: reverseOn)
    }

    /// Reverse is on: Censor held, or latched with Shift + Censor (#477).
    var reverseOn: Bool { held.contains(.censor) || latchedReverse != nil }
}
