// What the drawn display's chip knows (#465), decoded from the same messages it gets, by the same rules as
// tools/lc6000-display-fw/src/dfw.c: the Diagnostics preview draws from this, so it shows what the chip would.

public struct DrawnDisplayState: Equatable, Sendable {
    /// The deck in front, as its deck message gave it.
    public struct Deck: Equatable, Sendable {
        public var number: Int
        public var color: [Int]
        public var player: DrawnDisplay.Player
    }

    /// Between begin and end.
    public private(set) var drawn = false
    public private(set) var deck: Deck?
    public private(set) var flags: DrawnDisplay.State = []
    /// The master beat, 1-4, or 0 with none.
    public private(set) var beat = 0
    /// The needle, 0-16383; nil until a needle message.
    public private(set) var needle: Int?
    /// Level and held peak, 0-127; nil until a meter message.
    public private(set) var meter: (level: Int, peak: Int)? {
        get { meterValue.map { ($0[0], $0[1]) } }
        set { meterValue = newValue.map { [$0.level, $0.peak] } }
    }
    private var meterValue: [Int]?
    /// Each text field's Windows-1252 codes (0x81 the box); empty for none.
    public private(set) var texts: [DrawnDisplay.TextField: [UInt8]] = [:]
    /// Whether a text has come since the deck changed: until then no words are drawn.
    public private(set) var textHeard = false
    /// Tenths of a BPM, 0 for none.
    public private(set) var tempo = 0
    /// 1/16384 beats from the master, negative behind; DrawnPhase.unknown until the deck's own comes.
    public private(set) var phase = DrawnPhase.unknown
    /// The track time in whole seconds (#460), a length of 0 unknown; nil until a time message since the deck.
    public private(set) var time: (elapsed: Int, length: Int)? {
        get { timeValue.map { ($0[0], $0[1]) } }
        set { timeValue = newValue.map { [$0.elapsed, $0.length] } }
    }
    private var timeValue: [Int]?

    /// The clock, in ms, as the caller gives it (#569): the sequence cases' own times, or the preview's.
    private var nowMs = 0
    /// When the last of our messages came, and whether `silenceMs` have passed since (the waiting look).
    private var heardMs = 0
    public private(set) var silent = false
    /// When the time last changed: the warning's blink starts there.
    public private(set) var timeAtMs = 0

    /// The waiting look: the host says feedback stopped, or nothing came for `silenceMs`.
    public var stale: Bool { silent || flags.contains(.stale) }

    /// The track time's look (#460, #524), as dfw.c's time_look.
    public enum Look: Equatable, Sendable { case normal, red, white }

    public func look(atMs now: Int) -> Look {
        guard let time, time.length > 0, flags.contains(.playing), !flags.contains(.loopOn), !stale,
              time.length - time.elapsed <= DrawnDisplayProtocol.warningSeconds else { return .normal }
        if time.length - time.elapsed > DrawnDisplayProtocol.blinkSeconds { return .red }
        return ((now - timeAtMs) / DrawnDisplayProtocol.blinkHalfMs) % 2 == 0 ? .red : .white
    }

    public init() {}

    /// Applies a message at `now` ms.
    @discardableResult
    public mutating func apply(_ bytes: [UInt8], atMs now: Int) -> Bool {
        nowMs = now
        return apply(bytes)
    }

    /// The clock moved on to `now` ms: `silenceMs` with no message of ours is the waiting look.
    public mutating func tick(atMs now: Int) {
        nowMs = now
        if drawn, !silent, now - heardMs >= DrawnDisplayProtocol.silenceMs { silent = true }
    }

    /// Applies one whole message, F0 through F7, as the chip does; anything malformed or not ours changes nothing.
    /// Whether anything changed.
    @discardableResult
    public mutating func apply(_ bytes: [UInt8]) -> Bool {
        let before = self
        act(bytes)
        return self != before
    }

    private static let header: [UInt8] = DrawnDisplayProtocol.header + [DrawnDisplay.command]

    /// Each op's one exact length, counting the op; nil for text and for an op this version doesn't take (#569).
    private static func length(_ op: UInt8) -> Int? { DrawnDisplayProtocol.length(op) }

    private mutating func act(_ bytes: [UInt8]) {
        let header = Self.header
        guard bytes.count >= header.count + 4, Array(bytes.prefix(header.count)) == header, bytes.last == 0xF7,
              bytes.dropFirst().dropLast().allSatisfy({ $0 < 0x80 }) else { return }
        let declared = Int(bytes[header.count]) << 7 | Int(bytes[header.count + 1])
        guard bytes.count == header.count + 3 + declared, declared > 0 else { return }
        let op = bytes[header.count + 2]
        guard let kind = DrawnDisplayProtocol.Op(rawValue: op) else { return }
        let args = Array(bytes[(header.count + 3)..<(bytes.count - 1)])
        func word() -> Int { Int(args[0]) << 7 | Int(args[1]) }
        if kind == .text {
            guard declared >= 2, declared <= 2 + DrawnDisplay.textCap,
                  let field = DrawnDisplay.TextField(rawValue: args[0]), let codes = Self.decode(args.dropFirst()) else { return }
            heard()
            guard drawn else { return }
            textHeard = true
            texts[field] = codes
            return
        }
        guard let length = Self.length(op), declared == length, Self.inRange(kind, args) else { return }
        heard()
        switch kind {
        case .begin: drawn = true
        case .end:
            drawn = false
            deck = nil
            flags = []
            beat = 0
            needle = nil
            meter = nil
            phase = DrawnPhase.unknown
            time = nil
        case .deck:
            guard drawn, let player = DrawnDisplay.Player(rawValue: args[7]) else { return }
            let new = Deck(number: Int(args[0]),
                           color: [Int(args[1]) << 7 | Int(args[2]), Int(args[3]) << 7 | Int(args[4]), Int(args[5]) << 7 | Int(args[6])],
                           player: player)
            guard new != deck else { return }
            deck = new
            // A new deck's play flags, texts, tempo and phase wait for its own messages; only feedback stale carries over.
            flags = flags.intersection(.stale)
            texts = [:]
            tempo = 0
            textHeard = false
            phase = DrawnPhase.unknown
            time = nil
        case .tempo: if drawn { tempo = word() }
        case .state: if drawn { flags = DrawnDisplay.State(rawValue: args[0]) }
        case .beat: if drawn { beat = Int(args[0]) }
        case .needle: if drawn { needle = word() }
        case .meter: if drawn { meter = (Int(args[0]), Int(args[1])) }
        case .time:
            let new = [Int(args[0]) << 7 | Int(args[1]), Int(args[2]) << 7 | Int(args[3])]
            guard drawn, timeValue != new else { return }
            timeValue = new
            // The blink's phase starts again, red, when the time changes.
            timeAtMs = nowMs
        case .phase: if drawn { phase = word() >= 8192 ? word() - 16384 : word() }
        case .capability, .text: break
        }
    }

    /// Whether an op's arguments are in range, as dfw.c's in_range: versions aren't 0, a deck is 1-4 with channels up
    /// to 255 and a known player, a state's reserved bit is clear, a beat is 0-4.
    private static func inRange(_ kind: DrawnDisplayProtocol.Op, _ args: [UInt8]) -> Bool {
        switch kind {
        case .capability, .begin, .end: args[0] != 0
        case .deck:
            args[0] >= 1 && Int(args[0]) <= DrawnDisplayProtocol.deckMax && args[1] <= 1 && args[3] <= 1 && args[5] <= 1
                && Int(args[7]) <= DrawnDisplayProtocol.playerMax
        case .state: args[0] & UInt8(1 << DrawnDisplayProtocol.flagBits["reserved"]!) == 0
        case .beat: Int(args[0]) <= DrawnDisplayProtocol.beatMax
        case .text, .tempo, .time, .needle, .meter, .phase: true
        }
    }

    /// One of ours: it counts as hearing from the host, and ends any silence.
    private mutating func heard() {
        heardMs = nowMs
        silent = false
    }

    /// A text message's characters as Windows-1252 codes; nil if malformed: a code below 0x20, an escape with nothing
    /// after it, or one of the undefined codes other than 0x81 (the box).
    private static func decode(_ chars: ArraySlice<UInt8>) -> [UInt8]? {
        var codes: [UInt8] = []
        var iterator = chars.makeIterator()
        while let char = iterator.next() {
            if char == 0x7F {
                guard let next = iterator.next() else { return nil }
                let code = 0x80 | next
                if [0x8D, 0x8F, 0x90, 0x9D].contains(code) { return nil }
                codes.append(code)
            } else if char < 0x20 {
                return nil
            } else {
                codes.append(char)
            }
        }
        return codes
    }

    public static func == (a: DrawnDisplayState, b: DrawnDisplayState) -> Bool {
        a.drawn == b.drawn && a.deck == b.deck && a.flags == b.flags && a.beat == b.beat && a.needle == b.needle
            && a.meterValue == b.meterValue && a.texts == b.texts && a.textHeard == b.textHeard && a.tempo == b.tempo
            && a.phase == b.phase && a.timeValue == b.timeValue && a.silent == b.silent && a.timeAtMs == b.timeAtMs
    }
}
