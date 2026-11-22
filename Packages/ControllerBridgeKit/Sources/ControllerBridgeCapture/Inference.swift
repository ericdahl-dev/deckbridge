// What a step's raw messages say about the controls behind them (#185).

/// One channel voice message, cut down to what inference needs. Channels are 0-based here.
struct Voice {
    enum Kind { case noteOn, noteOff, cc, pitchBend }
    var kind: Kind
    var port: Int
    var channel: Int
    var number: Int
    var value: Int

    init?(_ bytes: [UInt8], port: Int = 0) {
        guard bytes.count >= 3 else { return nil }
        self.port = port
        channel = Int(bytes[0] & 0x0F)
        number = Int(bytes[1] & 0x7F)
        value = Int(bytes[2] & 0x7F)
        switch bytes[0] & 0xF0 {
        case 0x80: kind = .noteOff
        case 0x90: kind = .noteOn
        case 0xB0: kind = .cc
        case 0xE0:
            // LSB first on the wire; one 14-bit value, no number.
            kind = .pitchBend
            value = Int(bytes[2] & 0x7F) << 7 | Int(bytes[1] & 0x7F)
            number = 0
        default: return nil
        }
    }

    /// Which control sent it: note-on and note-off of one note are the same control.
    var control: ControlKey {
        let controlKind: ControlKind = switch kind {
        case .noteOn, .noteOff: .note
        case .cc: .cc
        case .pitchBend: .pitchBend
        }
        return ControlKey(kind: controlKind, port: port, channel: channel, number: number)
    }
}

struct ControlKey: Hashable {
    var kind: ControlKind
    var port: Int
    var channel: Int
    var number: Int
}

enum Inference {
    /// Which control a message comes from, for noise: the status with note-off folded into note-on, and the number
    /// ("90 34" for note 52 on channel 1). Pitch bend is its status alone, and a real-time message its one byte ("F8").
    /// Nil for anything else.
    static func noiseKey(_ bytes: [UInt8]) -> [UInt8]? {
        if isRealtime(bytes) { return bytes }
        guard let voice = Voice(bytes) else { return nil }
        let channel = UInt8(voice.channel)
        return switch voice.kind {
        case .noteOn, .noteOff: [0x90 | channel, UInt8(voice.number)]
        case .cc: [0xB0 | channel, UInt8(voice.number)]
        case .pitchBend: [0xE0 | channel]
        }
    }

    /// The controls in one step, in the order they first appear.
    static func controls(in messages: [(port: Int, bytes: [UInt8])], gesture: CaptureGesture) -> [ControlFacts] {
        let voices = messages.compactMap { Voice($0.bytes, port: $0.port) }
        let lsbOf = pairs(voices)
        let msbOf = Dictionary(uniqueKeysWithValues: lsbOf.map { ($1, $0) })
        var order: [ControlKey] = []
        var byControl: [ControlKey: [Voice]] = [:]
        for voice in voices {
            let key = msbOf[voice.control] ?? voice.control
            if byControl[key] == nil { order.append(key) }
            byControl[key, default: []].append(voice)
        }
        return order.compactMap { key in byControl[key].flatMap { facts(key, lsb: lsbOf[key], gesture: gesture, $0) } }
    }

    private static func facts(_ key: ControlKey, lsb: ControlKey?, gesture: CaptureGesture, _ voices: [Voice]) -> ControlFacts? {
        switch key.kind {
        case .note: noteFacts(key, voices)
        case .cc: ccFacts(key, lsb: lsb, gesture: gesture, voices)
        case .pitchBend: pitchBendFacts(key, voices)
        }
    }

    /// A one-byte system real-time message (clock, start, stop, active sensing, reset): never a control.
    static func isRealtime(_ bytes: [UInt8]) -> Bool { bytes.count == 1 && bytes[0] >= 0xF8 }

    /// The Shift button: the take's first note, still down when another control starts. When Shift is let go doesn't
    /// matter. With `releasedOnly` (a layer step, #325), only a control that's let go in the take counts: a layer
    /// indicator turns on unasked and stays on, so a layer button held while it arrives isn't taken for Shift.
    static func heldAround(_ messages: [(port: Int, bytes: [UInt8])], releasedOnly: Bool = false) -> ControlKey? {
        let voices = messages.compactMap { Voice($0.bytes, port: $0.port) }
        guard let first = voices.first, first.kind == .noteOn, first.value > 0 else { return nil }
        func isRelease(_ voice: Voice) -> Bool { voice.kind == .noteOff || (voice.kind == .noteOn && voice.value == 0) }
        let worked = voices.indices.first { index in
            let voice = voices[index]
            guard voice.control != first.control else { return false }
            if !releasedOnly || voice.kind == .cc || voice.kind == .pitchBend { return true }
            return voice.kind == .noteOn && voice.value > 0
                && voices[(index + 1)...].contains { $0.control == voice.control && isRelease($0) }
        }
        guard let other = worked else { return nil }
        let released = voices[..<other].contains { $0.control == first.control && isRelease($0) }
        return released ? nil : first.control
    }

    /// The controls without the held Shift note (#325: one rule for shifted and layer steps).
    static func removing(_ held: ControlKey, from controls: [ControlFacts]) -> [ControlFacts] {
        controls.filter { !($0.kind == .note && $0.port == held.port && $0.channel == held.channel + 1 && $0.number == held.number) }
    }

    /// 14-bit pairs, MSB to LSB, on one channel. CC n and n+32 pair first (the MIDI convention), when both came about
    /// as often. Two other CCs pair when their messages come side by side, as on the LC6000's Needle Drop (64 and
    /// 65), and the one sent first is the MSB. A CC is in one pair at most; ties go to the lower numbers.
    private static func pairs(_ voices: [Voice]) -> [ControlKey: ControlKey] {
        let ccs = voices.filter { $0.kind == .cc }.map(\.control)
        var counts: [ControlKey: Int] = [:]
        for key in ccs { counts[key, default: 0] += 1 }
        func similar(_ a: ControlKey, _ b: ControlKey) -> Bool {
            let x = Double(counts[a] ?? 0), y = Double(counts[b] ?? 0)
            return min(x, y) >= 0.8 * max(x, y)
        }

        var candidates: [(msb: ControlKey, lsb: ControlKey, convention: Bool, count: Int)] = []
        for key in counts.keys where key.number < 32 {
            let lsb = ControlKey(kind: .cc, port: key.port, channel: key.channel, number: key.number + 32)
            if counts[lsb] != nil, similar(key, lsb) { candidates.append((key, lsb, true, counts[key] ?? 0)) }
        }
        var adjacent: [[ControlKey]: Int] = [:]
        for (a, b) in zip(ccs, ccs.dropFirst()) where a.port == b.port && a.channel == b.channel && a.number != b.number {
            adjacent[[a, b], default: 0] += 1
        }
        for (keys, count) in adjacent {
            let fewer = min(counts[keys[0]] ?? 0, counts[keys[1]] ?? 0)
            if Double(count) >= 0.8 * Double(fewer), similar(keys[0], keys[1]) {
                candidates.append((keys[0], keys[1], false, count))
            }
        }
        candidates.sort {
            if $0.convention != $1.convention { return $0.convention }
            if $0.count != $1.count { return $0.count > $1.count }
            return ($0.msb.port, $0.msb.channel, $0.msb.number, $0.lsb.number) < ($1.msb.port, $1.msb.channel, $1.msb.number, $1.lsb.number)
        }

        var lsbOf: [ControlKey: ControlKey] = [:]
        var taken: Set<ControlKey> = []
        for candidate in candidates where !taken.contains(candidate.msb) && !taken.contains(candidate.lsb) {
            lsbOf[candidate.msb] = candidate.lsb
            taken.formUnion([candidate.msb, candidate.lsb])
        }
        return lsbOf
    }

    private static func ccFacts(_ key: ControlKey, lsb: ControlKey?, gesture: CaptureGesture, _ voices: [Voice]) -> ControlFacts? {
        var values: [Int] = []
        if let lsb {
            var msbValue: Int?
            for voice in voices {
                if voice.control == lsb, let msb = msbValue {
                    values.append(msb << 7 | voice.value)
                } else if voice.control == key {
                    msbValue = voice.value
                }
            }
        } else {
            values = voices.map(\.value)
        }
        guard let first = values.first, let last = values.last else { return nil }
        return ControlFacts(
            kind: .cc, port: key.port, channel: key.channel + 1, number: key.number, lsb: lsb?.number,
            encoding: lsb == nil && gesture == .turn ? encoding(values) : .absolute,
            first: first, last: last, min: values.min() ?? first, max: values.max() ?? first
        )
    }

    private static func noteFacts(_ key: ControlKey, _ voices: [Voice]) -> ControlFacts? {
        let presses = voices.filter { $0.kind == .noteOn && $0.value > 0 }.map(\.value)
        guard let first = presses.first, let last = presses.last else { return nil }
        let release: NoteRelease? =
            voices.contains { $0.kind == .noteOff } ? .noteOff
            : voices.contains { $0.kind == .noteOn && $0.value == 0 } ? .noteOnZero : nil
        return ControlFacts(
            kind: .note, port: key.port, channel: key.channel + 1, number: key.number, release: release,
            first: first, last: last, min: presses.min() ?? first, max: presses.max() ?? first
        )
    }

    private static func pitchBendFacts(_ key: ControlKey, _ voices: [Voice]) -> ControlFacts? {
        let values = voices.map(\.value)
        guard let first = values.first, let last = values.last else { return nil }
        return ControlFacts(
            kind: .pitchBend, port: key.port, channel: key.channel + 1, first: first, last: last,
            min: values.min() ?? first, max: values.max() ?? first
        )
    }

    /// How a turned 7-bit CC encodes its value. The prompt asks for a turn right, then left, so a relative encoder
    /// sends small steps both ways, often repeated. An absolute knob walks through its values without repeating.
    /// A relative-looking turn one way only can't be told apart (0x41 is offset-64 forward and sign-magnitude back),
    /// so its encoding is unknown (nil) rather than guessed.
    private static func encoding(_ values: [Int]) -> ControlEncoding? {
        let small = 1...0x1F, nearMiddleBack = 0x30...0x3F, nearMiddleForward = 0x41...0x50
        let twosBack = 0x61...0x7F, signBack = 0x41...0x5F
        func all(_ ranges: ClosedRange<Int>...) -> Bool { values.allSatisfy { v in ranges.contains { $0.contains(v) } } }
        func any(_ range: ClosedRange<Int>) -> Bool { values.contains { range.contains($0) } }
        if all(small, twosBack), any(small), any(twosBack) { return .twosComplement }
        if all(small, signBack), any(small), any(signBack) { return .signMagnitude }
        if all(nearMiddleBack, nearMiddleForward), any(nearMiddleBack), any(nearMiddleForward) { return .offset64 }
        let repeats = zip(values, values.dropFirst()).contains { $0 == $1 }
        let oneWay = all(small) || all(twosBack) || all(signBack) || all(nearMiddleBack) || all(nearMiddleForward)
        return repeats && oneWay ? nil : .absolute
    }
}
