// The level meter's ballistics (#582): Syndicate streams a mixer channel's raw level ~190 times a second, jumpy and at
// times above 1.0; its own channel meter looks smoother. This turns the stream into what the drawn meter shows, and the
// Diagnostics preview shows the same values: one implementation for both.

struct MeterBallistics: Sendable {
    /// The rise: instant (0 s), the user's meter rising with the hit.
    static let riseTime = 0.0
    /// The fall: full to empty in this long, linear. 0.5 s to start; tuned with the owner against Syndicate's meter.
    static let fallTime = 0.5
    /// How long the peak tick holds before it falls (the mixer LEDs' default, mixer.meter.hold_ms).
    static let peakHold = Double(ProfileKeys.fallback("mixer.meter.hold_ms") as Int) / 1000

    let riseTime: Double, fallTime: Double

    init(riseTime: Double = Self.riseTime, fallTime: Double = Self.fallTime) {
        self.riseTime = riseTime
        self.fallTime = fallTime
    }

    /// What's shown, 0...1: a place on the meter (MeterScale's), full being the red at clip.
    private(set) var level = 0.0
    private(set) var peak = 0.0

    /// The highest sample since the last step.
    private var pending: Double?
    /// Where the level last rose to, and when: it falls from there.
    private var risen = (level: 0.0, at: 0.0)
    private var peakSet = (level: 0.0, at: 0.0)
    private var lastStep: Double?

    /// A place on the meter, 0...1 (MeterScale.position of Syndicate's level).
    mutating func sample(_ value: Double, at time: Double) {
        let clipped = min(max(value, 0), 1)
        pending = max(pending ?? 0, clipped)
    }

    /// Moves the meter on to `time`: the highest sample since the last step rises at once; otherwise the level falls.
    mutating func step(at time: Double) {
        let target = pending ?? 0
        pending = nil
        defer { lastStep = time }
        let fallen = max(0, risen.level - (time - risen.at) / fallTime)
        if target >= fallen {
            // Instant with no rise time; otherwise full per riseTime from where it was.
            let rose = riseTime > 0 ? min(target, level + (time - (lastStep ?? time)) / riseTime) : target
            risen = (rose, time)
            level = rose
        } else {
            level = fallen
        }
        let held = time - peakSet.at <= Self.peakHold + 1e-9
            ? peakSet.level : peakSet.level - (time - peakSet.at - Self.peakHold) / fallTime
        if level >= held {
            peakSet = (level, time)
            peak = level
        } else {
            peak = held
        }
    }
}
