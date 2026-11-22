/// The jog wheel and the Needle Drop strip (#383). Playing, the jog bends (PhaseBend while it turns); paused, the jog
/// and the strip seek, with the deck's quantize held at None so Syndicate doesn't snap the seek to the grid (#366),
/// until 0.3 s after the last seek or the strip is let go. Plain values in, sends out: the Bridge sends the OSC, holds
/// the bend, and applies the quantize holds.
struct JogModule {
    enum Send: Equatable, Sendable {
        /// A message to this deck: its address after /Syndicate/Deck/N/.
        case osc(String, OSCArgument)
        case hold(QuantizeOverride.Reason)
        case release(QuantizeOverride.Reason)
        /// Bend this way (1 or −1) until `.endBend`: a held PhaseBend.
        case bend(Int)
        case endBend
    }

    /// How long after the last paused seek the deck's quantize goes back to Use Global (#366).
    static let seekQuantizeIdle = 0.3

    private var jogMSBValue: UInt8 = 0
    /// The platter's last 14-bit position, for the movement since.
    private var jogPosition: Int?
    private var needleMSBValue: UInt8 = 0
    private(set) var platterTouched = false
    private(set) var needleTouched = false
    /// The bend's direction while bending, else 0, and when the wheel last moved.
    private var bendDirection = 0
    private var lastJogTime = 0.0
    /// Where the deck is, 0–1: Syndicate's Progress, moved along by paused seeks.
    private(set) var progress: Double?
    /// Counts toward the next whole-beat skip, with no track length.
    private var seekCountRemainder = 0
    /// When the last paused seek went out, while its quantize hold is on.
    private var seekHeldSince: Double?
    /// When `progress` was last set, and whether the music moves it on (a playing deck, VINYL's seek, #547).
    private var progressAt = 0.0
    private var progressRuns = false
    /// While the hand moves, a report this many seconds of track from the jog's own place is a real jump (a cue, a
    /// load, the strip) and is followed; a nearer one is Syndicate's lead and is not (#585).
    static let jumpSeconds = 1.0

    var isBending: Bool { bendDirection != 0 }

    mutating func jogMSB(_ value: UInt8) { jogMSBValue = value }

    /// The platter's 14-bit position (#103). Movement is the change since the last position, taking the shorter way
    /// around the wrap at 16384, so 16376 → 3 is 11 forward. Read when the LSB arrives, so an MSB carry never jumps.
    mutating func jogLSB(_ value: UInt8, wheel: Mapping.Jog, playing: Bool, musicMoving: Bool = false, duration: Double?,
                         now: Double) -> [Send] {
        let position = join14Bit(msb: jogMSBValue, lsb: value)
        defer { jogPosition = position }
        guard let previous = jogPosition else { return [] }
        var counts = (position - previous) % 16384
        if counts > 8192 { counts -= 16384 } else if counts < -8192 { counts += 16384 }
        return jog(counts: counts, wheel: wheel, playing: playing, musicMoving: musicMoving, duration: duration, now: now)
    }

    /// The platter moved `counts`. A relative jog's edge (#204) moves without a touch (`needsTouch` false).
    /// `playing` is whether the jog bends; `musicMoving`, whether the deck plays (VINYL's seek on a playing deck).
    mutating func jog(counts: Int, needsTouch: Bool = true, wheel: Mapping.Jog, playing: Bool, musicMoving: Bool = false,
                      duration: Double?, now: Double) -> [Send] {
        guard counts != 0, platterTouched || !wheel.requireTouch || !needsTouch else { return [] }
        lastJogTime = now
        if playing {
            let direction = counts > 0 ? 1 : -1
            guard direction != bendDirection else { return [] }
            bendDirection = direction
            return [.bend(direction)]
        }
        // The check keeps these positive; a hand-built mapping with 0 mustn't trap (#92).
        let countsPerRev = Double(wheel.countsPerRev)
        guard countsPerRev > 0 else { return [] }
        let revolutions = Double(counts) / countsPerRev
        // Paused: move the playhead.
        if let duration, let position = place(now: now, duration: duration) {
            let moved = min(1, max(0, position + revolutions * wheel.seekSecondsPerRev / duration))
            setProgress(moved, at: now, runs: musicMoving)
            return pausedSeek(Float(moved), now: now)
        }
        // No track length: skip whole beats, keeping the remainder for the next turn.
        let countsPerBeat = Int((countsPerRev / wheel.beatsPerRev).rounded())
        guard countsPerBeat > 0 else { return [] }
        seekCountRemainder += counts
        let beats = seekCountRemainder / countsPerBeat
        guard beats != 0 else { return [] }
        seekCountRemainder -= beats * countsPerBeat
        return [.osc("BeatSkip", .int(Int32(beats)))]
    }

    mutating func needleMSB(_ value: UInt8) { needleMSBValue = value }

    /// The strip's position, 0–1, once its LSB arrives.
    func needlePosition(lsb: UInt8) -> Double { Double(join14Bit(msb: needleMSBValue, lsb: lsb)) / 16383 }

    /// The strip's 14-bit position (#103), as a seek across the whole track. Sent when the LSB arrives, so an MSB on
    /// its own never seeks to a half-updated place.
    mutating func needleLSB(_ value: UInt8, needle: Mapping.Needle, playing: Bool, now: Double) -> [Send] {
        guard needleTouched || !needle.requireTouch else { return [] }
        let fraction = Float(Double(join14Bit(msb: needleMSBValue, lsb: value)) / 16383)
        // Paused, unquantized (#366); playing, a seek in time with the grid, as Syndicate does it.
        return playing ? [.osc("WaveformSeek", .float(fraction))] : pausedSeek(fraction, now: now)
    }

    /// The strip touched or let go: let go, its seeks are done (#366).
    mutating func needleTouch(_ pressed: Bool) -> [Send] {
        needleTouched = pressed
        guard !pressed else { return [] }
        seekHeldSince = nil
        return [.release(.jogSeek)]
    }

    @discardableResult
    mutating func platterTouch(_ pressed: Bool) -> [Send] {
        platterTouched = pressed
        return !pressed && isBending ? endBend() : []
    }

    /// Syndicate's Playing: a deck that stops ends the bend.
    mutating func playingChanged(_ playing: Bool) -> [Send] {
        !playing && isBending ? endBend() : []
    }

    /// Syndicate's Progress, or nil when the track is gone or feedback stopped.
    ///
    /// While the hand moves (the seek's quantize hold is on), the jog keeps its own place: Syndicate reports a seek's
    /// place about 0.1 s ahead of it (#585, the owner's trace), and taking each report put every next seek further on,
    /// so a stopped deck crept forward whichever way the platter turned. A report more than `jumpSeconds` from the
    /// jog's own place is a real jump and is taken.
    mutating func progressReported(_ value: Double?, duration: Double? = nil, now: Double = 0) {
        if let value, seekHeldSince != nil, let duration, duration > 0, let own = place(now: now, duration: duration),
           abs(value - own) * duration <= Self.jumpSeconds {
            return
        }
        setProgress(value, at: now, runs: false)
    }

    /// The jog's own place at `now`: where it last was, run on with the music if it plays.
    private func place(now: Double, duration: Double) -> Double? {
        guard let progress else { return nil }
        return progressRuns ? min(1, progress + max(0, now - progressAt) / duration) : progress
    }

    private mutating func setProgress(_ value: Double?, at time: Double, runs: Bool) {
        progress = value
        progressAt = time
        progressRuns = runs
    }

    /// The wheel stopped for bend_release_ms: the bend ends. The seeking stopped for 0.3 s: quantize back.
    mutating func tick(now: Double, wheel: Mapping.Jog?) -> [Send] {
        var sends: [Send] = []
        if let wheel, isBending, now - lastJogTime >= Double(wheel.bendReleaseMs) / 1000 { sends += endBend() }
        if let since = seekHeldSince, now - since >= Self.seekQuantizeIdle - 1e-9 {
            seekHeldSince = nil
            sends.append(.release(.jogSeek))
        }
        return sends
    }

    /// Everything is released (the Bridge's held bend among it): nothing is touched or bending any more.
    mutating func releaseAll() {
        bendDirection = 0
        platterTouched = false
        needleTouched = false
    }

    /// A new port or device: the next platter position starts fresh, with no movement from the old one.
    mutating func forgetPlatter() { jogPosition = nil }

    private mutating func endBend() -> [Send] {
        bendDirection = 0
        return [.endBend]
    }

    private mutating func pausedSeek(_ fraction: Float, now: Double) -> [Send] {
        seekHeldSince = now
        return [.hold(.jogSeek), .osc("WaveformSeek", .float(fraction))]
    }
}
