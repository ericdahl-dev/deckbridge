// Pads, pad modes and cue colors (#18), as in the Python bridge.

/// What the pads do.
enum PadMode: CaseIterable {
    case hotCue, roll, loop, slicer

    /// The next mode for a cycling button (#198): Hot Cue → Roll → Loop → Slicer → Hot Cue.
    var next: PadMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

extension Bridge {
    /// ColorPalette feedback (#18): the pad module keeps the cue colors; the pads repaint.
    func colorPalette(_ arguments: [OSCArgument]) {
        if padModule.paletteFeedback(arguments) { refreshLEDs() }
    }

    /// A mode button. Switching mode first releases any held pad, so a hot cue or roll never sticks.
    func padModeButton(_ mode: PadMode) -> (Bool) -> Void {
        { pressed in
            guard pressed else { return }
            self.applyPads(self.padModule.modeButton(mode))
            self.refreshLEDs()
        }
    }

    /// The one cycling mode button (#198); with the LC6000's four buttons it does nothing.
    func padModeCycle(_ pressed: Bool) {
        guard pressed else { return }
        let sends = padModule.cycle()
        guard !sends.isEmpty else { return }
        applyPads(sends)
        refreshLEDs()
    }

    /// A pad note in. A note from another mode's list (#225) switches to that mode first, letting held pads go, as
    /// a mode button does.
    func padNote(_ note: Int, pressed: Bool) -> Bool {
        let index: Int
        if pressed {
            guard let press = padModule.press(note: note) else { return false }
            applyPads(press.sends)
            index = press.index
        } else {
            guard let pad = padModule.pad(for: note) else { return false }
            index = pad.index
        }
        handlePad(index, pressed: pressed)
        return true
    }

    /// The pad a note plays (#225).
    func pad(for note: Int) -> (index: Int, mode: PadMode?)? { padModule.pad(for: note) }

    /// The notes the pads send and light in `mode` (#225).
    func padNotes(for mode: PadMode) -> [Int] { padModule.notes(for: mode) }

    /// Does what the pad module asks.
    func applyPads(_ sends: [PadModule.Send]) {
        for send in sends {
            switch send {
            case .releasePads: releasePads()
            case .hold(let index, let path, let press, let release): hold(.pad(index), path, press: press, release: release)
            case .release(let index): releaseHold(.pad(index))
            case .osc(let path, let argument): sendDeck(path, argument)
            case .cueJump(let cue): goToCuePaused(cue)
            }
        }
    }

    /// Releases every held pad, and nothing else.
    func releasePads() {
        for index in mapping.notes.pads.indices { releaseHold(.pad(index)) }
    }

    /// Syndicate's hot cues per deck (#311).
    static let syndicateCues = PadModule.syndicateCues

    /// A pad press or release. `index` is 0-based, so hot cue `index + 1`.
    func handlePad(_ index: Int, pressed: Bool) {
        defer { refreshLEDs() }
        applyPads(pressed ? padModule.pressed(index, PadModule.Facts(shift: shift, playing: playing, playPending: playPending))
                          : padModule.released(index))
    }

    /// Shift + hot cue pad on a stopped deck (#358, #363): the cue module decides; the Bridge sends.
    func goToCuePaused(_ cue: Int) {
        applyCues(cueMemory.shiftPad(cue, duration: duration, now: clock.now))
    }

    /// A new track, or none: its cue times and cue point are unknown again.
    func forgetCues() {
        end(.newTrack)
        applyCues(cueMemory.forgetTrack())
    }

    /// Sends what the cue module asks: OSC to this deck, and quantize holds through the Bridge's one QuantizeOverride.
    func applyCues(_ sends: [CueModule.Send]) {
        for send in sends {
            switch send {
            case .osc(let path, let argument): sendDeck(path, argument)
            case .hold(let reason): overrideQuantize(reason)
            case .release(let reason): restoreQuantize(reason)
            }
        }
    }

    // MARK: LEDs

    func padLEDs() {
        let modes: [(String, PadMode)] = [("mode_hotcue", .hotCue), ("mode_roll", .roll), ("mode_loop", .loop), ("mode_slicer", .slicer)]
        for (name, mode) in modes { buttonLED(name, on: padMode == mode) }
        cycleButtonLED()
        // With notes per mode (#225), the current mode's notes carry the colors and the other modes' go dark.
        let rgb = padRGB()
        for (index, (note, velocity)) in zip(padNotes(for: padMode), padColors()).enumerated() {
            // A pad that takes Denon's color message (#531) shows its exact color; any other its velocity.
            if index < rgb.count, let message = colorMessageEncoder?.message(note: note, rgb: rgb[index]) {
                colorLED(message)
            } else {
                padLED(note, velocity)
            }
        }
        let lit = Set(padNotes(for: padMode))
        for note in padModule.allModeNotes where !lit.contains(note) { padLED(note, Self.off) }
        ringLED()
    }

    /// The cycling button's own LED (#198): the profile's velocity for the current mode. With none, it's left alone.
    private func cycleButtonLED() {
        guard mapping.pads.modeSelect == .cycle, let levels = mapping.pads.modeCycleVelocities,
              let note = mapping.notes.buttons["mode_cycle"] else { return }
        let velocity = switch padMode {
        case .hotCue: levels.hotcue
        case .roll: levels.roll
        case .loop: levels.loop
        case .slicer: levels.slicer
        }
        led(note, UInt8(clamping: velocity))
    }

    /// Each pad's velocity in the current mode, from the pad module, with which pads are held.
    func padColors() -> [UInt8] {
        let heldPads = Set(mapping.notes.pads.indices.filter { held.contains(.pad($0)) })
        return padModule.velocities(held: heldPads, ringColors: ringColors)
    }

    /// Each pad's exact color in the current mode (#531), with which pads are held.
    func padRGB() -> [[Int]] {
        let heldPads = Set(mapping.notes.pads.indices.filter { held.contains(.pad($0)) })
        return padModule.colors(held: heldPads)
    }

    /// The ring's and a held pad's velocity, by the Settings mapping (#151), through the profile's color table (#197).
    func ringVelocity(_ rgb: [Int]) -> UInt8 {
        ringColors == .vivid ? mapping.leds.colorTable.vivid(for: rgb) : velocity(rgb)
    }

    /// A pad or ring velocity for an [r, g, b] color, through the profile's color table (#197). Not three values
    /// (a user mapping the check didn't see): off.
    func velocity(_ rgb: [Int]) -> UInt8 {
        mapping.leds.colorTable.velocity(for: rgb)
    }
}

extension OSCArgument {
    /// An int, or a float cut to an int as the Python bridge's int() does. A NaN, an infinity or a float too big
    /// for an Int (feedback is untrusted UDP) gives nil instead of trapping.
    var wholeNumber: Int? {
        switch self {
        case .int(let value): Int(value)
        case .float(let value): Int(exactly: value.rounded(.towardZero))
        case .string: nil
        }
    }
}
