// The live part of the drawn display (#524, #465): what changes between the deck's own messages, as the chip draws it.
// The renderer's drawnImage takes it beside the deck's JogDisplayContent; the Diagnostics preview builds it from
// DrawnDisplayState and its own clock (the warning's look).

public struct DrawnLive: Equatable, Sendable {
    public struct Meter: Equatable, Sendable {
        public var level: Int, peak: Int
        public init(level: Int, peak: Int) { self.level = level; self.peak = peak }
    }

    public struct Time: Equatable, Sendable {
        /// Whole seconds; a length of 0 is unknown.
        public var elapsed: Int, length: Int
        public init(elapsed: Int, length: Int) { self.elapsed = elapsed; self.length = length }
    }

    /// The master beat, 1-4; nil or 0 for none lit.
    public var beat: Int?
    /// The needle, 0-16383 for one turn clockwise from 12 o'clock (op 09's scale); nil for none.
    public var needle: Int?
    /// Level and held peak, 0-127 each; nil draws no meter.
    public var meter: Meter?
    /// 1/16384 beats from the master (op 0B); nil is unknown.
    public var phase: Int?
    public var time: Time?
    /// The last minute's warning now, from JogTrackTime.look.
    public var look: JogTrackTime.Look

    public init(beat: Int? = nil, needle: Int? = nil, meter: Meter? = nil, phase: Int? = nil, time: Time? = nil,
                look: JogTrackTime.Look = .normal) {
        self.beat = beat
        self.needle = needle
        self.meter = meter
        self.phase = phase
        self.time = time
        self.look = look
    }
}
