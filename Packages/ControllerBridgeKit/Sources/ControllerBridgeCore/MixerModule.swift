/// The mixer section (#207, #320, #321, #383): channel faders, trim, EQ and filter knobs with pickup, cue/mute/solo, and
/// the VU meter, for the mixer channel of the controller's deck. Plain values in, sends out: the Bridge addresses them
/// to its channel (MixerOSC) and drives the LEDs.
struct MixerModule {
    enum Send: Equatable, Sendable {
        /// A fader or knob's level, 0..1, rounded as sent.
        case value(MixerValue, Double)
        /// Cue, mute or solo: the new state, 1 or 0.
        case button(MixerValue, Int32)
        /// Syndicate reported a button: repaint the cue, mute and solo LEDs.
        case buttonLEDs
    }

    /// How long after a send its echo may still come back from Syndicate.
    static let echoWindow = 0.5

    /// A 14-bit control's MSB, kept until its LSB arrives.
    private var msb: [MixerValue: UInt8] = [:]
    /// The last value sent per control, rounded as sent.
    private var lastSent: [MixerValue: Double] = [:]
    /// Recent sends, for telling Syndicate's echo from an outside change.
    private var recentSends: [MixerValue: [(time: Double, value: Double)]] = [:]
    /// What Syndicate last reported per control.
    private var reported: [MixerValue: Double] = [:]
    /// Controls waiting to meet Syndicate's value (pickup), and where each last was.
    private var armed: Set<MixerValue> = []
    private var position: [MixerValue: Double] = [:]
    /// Just after a deck switch, controls with no report from the new channel wait until then (#321).
    private var waitUntil: Double?
    /// The meter: Syndicate's latest level, the peak being held and since when, and what the LEDs show.
    private var meterLevel: Double?
    private var meterPeak = 0.0
    private var meterPeakAt = -Double.infinity
    private var meterSentAt: Double?
    private(set) var meterShownValue: UInt8?

    /// The faders and knobs, with the value each drives.
    static func controls(_ mixer: Mapping.Mixer) -> [(value: MixerValue, control: Mapping.Control)] {
        let all: [(MixerValue, Mapping.Control?)] = [
            (.volume, mixer.volume), (.trim, mixer.trim), (.eqHigh, mixer.eqHigh), (.eqMid, mixer.eqMid),
            (.eqLow, mixer.eqLow), (.filterCut, mixer.filter), (.filterRes, mixer.filterRes), (.filterWidth, mixer.filterWidth),
        ]
        return all.compactMap { value, control in control.map { (value, $0) } }
    }

    /// The cue, mute and solo buttons, with the value each toggles.
    static func buttons(_ mixer: Mapping.Mixer) -> [(value: MixerValue, note: Int)] {
        let all: [(MixerValue, Int?)] = [(.cue, mixer.cueNote), (.mute, mixer.muteNote), (.solo, mixer.soloNote)]
        return all.compactMap { value, note in note.map { (value, $0) } }
    }

    /// A CC from a fader or knob: sent as 0..1 once it's whole. Nil for a CC that isn't the mixer's.
    mutating func cc(_ controller: Int, value: UInt8, mixer: Mapping.Mixer, now: Double) -> [Send]? {
        for (kind, control) in Self.controls(mixer) {
            if control.msbCC == controller {
                if control.bits == 7 { return send(kind, mixerLevel(from7Bit: value), mixer: mixer, now: now) }
                msb[kind] = value
                return []
            }
            if control.bits == 14, control.lsbCC == controller {
                return send(kind, mixerLevel(from14Bit: join14Bit(msb: msb[kind] ?? 0, lsb: value)), mixer: mixer, now: now)
            }
        }
        return nil
    }

    /// A press of cue, mute or solo sends the opposite of what Syndicate last reported: they're switches that set the
    /// state (User Guide 14.9; Mute confirmed by the #207 spike, Cue not yet). Its LED waits for Syndicate's answer.
    /// Nil for a note that isn't the mixer's.
    func note(_ note: Int, pressed: Bool, mixer: Mapping.Mixer) -> [Send]? {
        guard let button = Self.buttons(mixer).first(where: { $0.note == note }) else { return nil }
        guard pressed else { return [] }
        let on = (reported[button.value] ?? 0) > 0.5
        return [.button(button.value, on ? 0 : 1)]
    }

    /// Syndicate's report of a mixer value on this channel.
    mutating func feedback(_ kind: MixerValue, _ value: Double, mixer: Mapping.Mixer, now: Double) -> [Send] {
        if Self.controls(mixer).contains(where: { $0.value == kind }) { controlReported(kind, value, mixer: mixer, now: now) }
        if kind == .meter, let meter = mixer.meter {
            meterLevel = value
            if value >= meterPeak || now - meterPeakAt > Double(meter.holdMs) / 1000 {
                meterPeak = value
                meterPeakAt = now
            }
        }
        guard Self.buttons(mixer).contains(where: { $0.value == kind }) else { return [] }
        reported[kind] = value
        return [.buttonLEDs]
    }

    /// The cue, mute and solo LEDs: on when Syndicate reported them on.
    func buttonLEDs(mixer: Mapping.Mixer) -> [(note: Int, on: Bool)] {
        Self.buttons(mixer).map { ($0.note, (reported[$0.value] ?? 0) > 0.5) }
    }

    /// The meter's CC value to show now, at most `rate_hz` times a second: the peak while it holds, else the level.
    /// Nil when there's nothing new. The Bridge calls `meterShown` once it's out.
    mutating func meterTick(mixer: Mapping.Mixer, now: Double) -> UInt8? {
        guard let meter = mixer.meter, let level = meterLevel else { return nil }
        if let sent = meterSentAt, now - sent < 1 / Double(max(1, meter.rateHz)) - 1e-9 { return nil }
        if now - meterPeakAt > Double(meter.holdMs) / 1000 {
            meterPeak = level
            meterPeakAt = now
        }
        let value = Self.meterValue(max(level, meterPeak), meter)
        return value == meterShownValue ? nil : value
    }

    mutating func meterShown(_ value: UInt8, now: Double) {
        meterShownValue = value
        meterSentAt = now
    }

    /// The meter LEDs may show anything now (a new port, LEDs off or on): shown again on the next tick.
    mutating func forgetMeterShown() { meterShownValue = nil }

    /// Every fader and knob waits to meet Syndicate again (#321): after a capture swept them, or a replug.
    mutating func rearm(mixer: Mapping.Mixer?) {
        let kinds = mixer.map { Self.controls($0).map(\.value) } ?? []
        for kind in kinds {
            armed.insert(kind)
            position[kind] = nil
            lastSent[kind] = nil
        }
        msb = [:]
    }

    /// Another deck, another mixer channel (#321): the old channel's reports are forgotten, and the faders wait for
    /// the new channel's values for the answer window.
    mutating func forgetChannel(mixer: Mapping.Mixer?, now: Double, answerWindow: Double) {
        reported = [:]
        recentSends = [:]
        rearm(mixer: mixer)
        waitUntil = now + answerWindow
    }

    private mutating func send(_ kind: MixerValue, _ level: Double, mixer: Mapping.Mixer, now: Double) -> [Send] {
        let rounded = (level * 100_000).rounded() / 100_000
        guard pickedUp(kind, at: rounded, mixer: mixer, now: now), rounded != lastSent[kind] else { return [] }
        lastSent[kind] = rounded
        recentSends[kind, default: []].removeAll { now - $0.time > Self.echoWindow }
        recentSends[kind, default: []].append((now, rounded))
        return [.value(kind, rounded)]
    }

    /// A value the controller didn't send (another controller, the mouse) moved Syndicate away from the control, so
    /// pickup arms, as the pitch fader's (#22). Syndicate's echo of a send doesn't.
    private mutating func controlReported(_ kind: MixerValue, _ value: Double, mixer: Mapping.Mixer, now: Double) {
        reported[kind] = value
        guard mixer.pickup else { return }
        let tolerance = mixer.pickupTolerance
        let echo = lastSent[kind].map { abs($0 - value) <= tolerance } == true
            || (recentSends[kind] ?? []).contains { now - $0.time <= Self.echoWindow && abs($0.value - value) <= tolerance }
        if !echo {
            armed.insert(kind)
            position[kind] = nil
            lastSent[kind] = nil
        }
    }

    /// Whether the control at `level` drives Syndicate: always unless armed; armed, once it's within tolerance of the
    /// reported value or moves across it.
    private mutating func pickedUp(_ kind: MixerValue, at level: Double, mixer: Mapping.Mixer, now: Double) -> Bool {
        guard mixer.pickup else { return true }
        guard let reported = reported[kind] else {
            // No report yet: it passes through, except just after a deck switch, while the new channel's is due.
            if let until = waitUntil, now < until { return false }
            return true
        }
        guard armed.contains(kind) else { return true }
        let previous = position[kind]
        position[kind] = level
        let near = abs(level - reported) <= mixer.pickupTolerance
        let crossed = previous.map { ($0 - reported) * (level - reported) < 0 } ?? false
        guard near || crossed else { return false }
        armed.remove(kind)
        return true
    }

    /// The meter CC value for a level: the step for the share of segments lit, or the clip value above 1.0.
    private static func meterValue(_ level: Double, _ meter: Mapping.Mixer.Meter) -> UInt8 {
        guard let top = meter.steps.last else { return 0 }
        if level > 1 { return UInt8(clamping: meter.clip ?? top) }
        let index = min(meter.steps.count - 1, max(0, Int((level * Double(meter.steps.count - 1)).rounded(.down))))
        return UInt8(clamping: meter.steps[index])
    }
}
