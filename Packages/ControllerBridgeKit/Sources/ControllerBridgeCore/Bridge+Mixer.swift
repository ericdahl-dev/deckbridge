// The mixer section (#207): channel faders, trim, EQ and filter knobs, cue/mute/solo, and VU meters, on mixer channel
// N for the controller driving deck N. Addresses are in MixerOSC (inputs confirmed by the #207 spike, but for Cue).

extension Bridge {
    /// A CC from one of the mixer's faders or knobs (#383: MixerModule). False for any other CC.
    func mixerCC(_ controller: Int, value: UInt8) -> Bool {
        guard let mixer = mapping.mixer, let sends = mixerModule.cc(controller, value: value, mixer: mixer, now: clock.now) else { return false }
        applyMixer(sends)
        return true
    }

    /// A press of cue, mute or solo. False for any other note.
    func mixerNote(_ note: Int, pressed: Bool) -> Bool {
        guard let mixer = mapping.mixer, let sends = mixerModule.note(note, pressed: pressed, mixer: mixer) else { return false }
        applyMixer(sends)
        return true
    }

    /// Syndicate's report of a mixer value on this deck's channel.
    func mixerFeedback(_ kind: MixerValue, _ arguments: [OSCArgument]) {
        guard let mixer = mapping.mixer, let value = arguments.first?.number else { return }
        applyMixer(mixerModule.feedback(kind, value, mixer: mixer, now: clock.now))
    }

    /// The cue, mute and solo LEDs, from what Syndicate reported: full when on, else as an unlit button.
    func mixerLEDs() {
        guard let mixer = mapping.mixer else { return }
        for button in mixerModule.buttonLEDs(mixer: mixer) {
            led(button.note, button.on ? fullLevel : (mapping.leds.dimUnlitButtons ? dimLevel : offLevel))
        }
    }

    /// Puts the meter on its LEDs, at most `rate_hz` times a second. Syndicate sends Meter around 200 times a second,
    /// far more than the LEDs need or the port should carry.
    func meterTick() {
        guard let mixer = mapping.mixer, let meter = mixer.meter, let value = mixerModule.meterTick(mixer: mixer, now: clock.now) else { return }
        guard ledCC(UInt8(meter.cc), value) else { return }
        mixerModule.meterShown(value, now: clock.now)
    }

    /// Every fader and knob waits to meet Syndicate again (#321): after a capture swept them, or a replug.
    func rearmMixer() { mixerModule.rearm(mixer: mapping.mixer) }

    /// Another deck, another mixer channel (#321).
    func forgetMixerChannel() {
        mixerModule.forgetChannel(mixer: mapping.mixer, now: clock.now, answerWindow: Double(mapping.osc.feedbackAnswerMs) / 1000)
    }

    /// Sends what the mixer module asks, on this deck's mixer channel.
    private func applyMixer(_ sends: [MixerModule.Send]) {
        for send in sends {
            switch send {
            case .value(let kind, let level):
                self.send(address: MixerOSC.address(kind, channel: mapping.deck.number, root: root), [.float(Float(level))])
            case .button(let kind, let state):
                self.send(address: MixerOSC.address(kind, channel: mapping.deck.number, root: root), [.int(state)])
            case .buttonLEDs: mixerLEDs()
            }
        }
    }
}

/// A 7-bit mixer control's value as 0..1. Syndicate centers EQ and trim at 0.5, so 64 (a knob's detent) is exactly
/// 0.5: below it each step is 1/128, above it 1/126, so 0 and 127 reach the ends (the 7-bit pitch fader's rule, #195).
func mixerLevel(from7Bit value: UInt8) -> Double {
    let v = Double(value & 0x7F)
    return v < 64 ? v / 128 : 0.5 + (v - 64) / 126
}

/// A 14-bit mixer control's value as 0..1, with 8192 exactly 0.5 by the same rule.
func mixerLevel(from14Bit value: Int) -> Double {
    let v = Double(max(0, min(16383, value)))
    return v < 8192 ? v / 16384 : 0.5 + (v - 8192) / 16382
}
