/// The Bridge's pads as a module (#383 slice 5): the pad mode and which note plays which pad (#18, #198, #225).
/// Plain values in, sends out; the Bridge applies them (holds, OSC, LEDs), as CueModule (#408) does.
struct PadModule {
    enum Send: Equatable, Sendable {
        /// Let every held pad go (a mode change), so a hot cue or roll never sticks.
        case releasePads
        /// Hold `path` for pad `index`: `press` now, `release` when the pad (or everything) lets go.
        case hold(Int, String, press: [OSCArgument], release: [OSCArgument])
        /// Pad `index` let go.
        case release(Int)
        /// A message to this deck: its address after /Syndicate/Deck/N/.
        case osc(String, OSCArgument)
        /// Shift + hot cue pad on a stopped deck (#358): go to cue `n` without playing; CueModule decides how.
        case cueJump(Int)
    }

    /// What a press depends on beyond the pads: Shift, and whether the deck is stopped.
    struct Facts: Equatable, Sendable {
        var shift: Bool
        var playing: Bool
        var playPending: Bool
    }

    /// Syndicate's hot cues per deck: its Cues feedback has eight slots. A pad past them has no cue (#311).
    static let syndicateCues = 8
    private let rollSizes: [String]
    private let leds: Mapping.LEDs
    /// Each pad's cue color slot, from Cues feedback; 0 is no cue.
    private(set) var cues: [Int]
    /// Syndicate's cue colors by slot, from ColorPalette feedback (#18).
    private var palette = PadModule.defaultPalette

    /// Syndicate's default cue colors by slot.
    static let defaultPalette: [Int: [Int]] = [
        1: [255, 0, 0], 2: [255, 128, 0], 3: [255, 255, 0], 4: [0, 255, 0],
        5: [0, 255, 255], 6: [0, 0, 255], 7: [128, 0, 255], 8: [255, 0, 255],
    ]
    static let off: UInt8 = 0

    private let pads: Mapping.Pads
    /// `notes.pads`: the notes the pads send in every mode, unless the profile gives each mode its own (#225).
    private let padNotes: [Int]
    private(set) var mode = PadMode.hotCue

    init(mapping: Mapping) {
        pads = mapping.pads
        padNotes = mapping.notes.pads
        rollSizes = mapping.pads.rollSizes
        leds = mapping.leds
        cues = [Int](repeating: 0, count: mapping.notes.pads.count)
    }

    /// The bridge's own state across a settings swap (#115): the pad mode.
    mutating func carry(from old: PadModule) {
        mode = old.mode
    }

    /// Syndicate's feedback across a settings swap: the cues and the palette.
    mutating func carryFeedback(from old: PadModule) {
        cues = old.cues
        palette = old.palette
    }

    // MARK: Cues and colors

    /// Cues feedback: a slot and a name per cue, one per pad (#196). Syndicate sends 8; pads past what it sends are
    /// empty.
    mutating func cuesFeedback(_ arguments: [OSCArgument]) {
        let slots = stride(from: 0, to: arguments.count, by: 2).prefix(cues.count).map { index -> Int in
            if case .int(let slot) = arguments[index] { return Int(slot) }
            return 0
        }
        cues = slots + Array(repeating: 0, count: max(0, cues.count - slots.count))
    }

    /// No cues (a track gone, Syndicate gone): `count` empty slots.
    mutating func clearCues(count: Int) {
        cues = [Int](repeating: 0, count: count)
    }

    /// ColorPalette feedback: a slot, then its red, green and blue (0-255), several slots flattened in groups of four.
    /// False when there wasn't a whole group, so nothing changed.
    mutating func paletteFeedback(_ arguments: [OSCArgument]) -> Bool {
        let numbers = arguments.compactMap(\.wholeNumber)
        guard numbers.count >= 4 else { return false }
        for start in stride(from: 0, through: numbers.count - 4, by: 4) {
            palette[numbers[start]] = Array(numbers[(start + 1)...(start + 3)])
        }
        return true
    }

    /// Each pad's LED velocity in the current mode. Hot Cue: each cue in its color, a held one in its brightest
    /// version, vivid by Settings (#151). Loop: each cue in the loop color. Roll: every pad with a roll size in the
    /// roll color (#311). Slicer: off. An empty cue is off.
    func velocities(held: Set<Int>, ringColors: RingColors) -> [UInt8] {
        switch mode {
        case .hotCue:
            return cues.enumerated().map { index, slot in
                guard slot != 0 else { return Self.off }
                let color = palette[slot] ?? [255, 255, 255]
                guard held.contains(index) else { return velocity(color) }
                let bright = Self.brightest(color)
                return ringColors == .vivid ? leds.colorTable.vivid(for: bright) : velocity(bright)
            }
        case .loop: return cues.map { $0 == 0 ? Self.off : velocity(leds.loopPadColor) }
        case .roll: return cues.indices.map { $0 < rollSizes.count ? velocity(leds.rollPadColor) : Self.off }
        case .slicer: return Array(repeating: Self.off, count: cues.count)
        }
    }

    /// Each pad's color in the current mode, as 8-bit RGB, for the color message (#531): what `velocities` shows,
    /// without the 64-color table. An empty pad is off, as with the table.
    func colors(held: Set<Int>) -> [[Int]] {
        switch mode {
        case .hotCue:
            return cues.enumerated().map { index, slot in
                guard slot != 0 else { return [0, 0, 0] }
                let color = palette[slot] ?? [255, 255, 255]
                // Held: brighter in its own color, exact (no vivid rounding with the color message).
                return held.contains(index) ? Self.brightest(color) : color
            }
        // As `velocities`: Loop on the pads with a cue, Roll on the pads with a roll size (#311), Slicer off.
        case .loop: return cues.map { $0 == 0 ? [0, 0, 0] : leds.loopPadColor }
        case .roll: return cues.indices.map { $0 < rollSizes.count ? leds.rollPadColor : [0, 0, 0] }
        case .slicer: return Array(repeating: [0, 0, 0], count: cues.count)
        }
    }

    /// The color scaled up so its strongest channel is 255.
    static func brightest(_ rgb: [Int]) -> [Int] {
        guard let top = rgb.max(), top > 0 else { return rgb }
        return rgb.map { $0 * 255 / top }
    }

    private func velocity(_ rgb: [Int]) -> UInt8 { leds.colorTable.velocity(for: rgb) }

    /// A mode button (pressed): held pads go, then the mode switches.
    mutating func modeButton(_ mode: PadMode) -> [Send] {
        self.mode = mode
        return [.releasePads]
    }

    /// The one cycling mode button (#198), for a profile whose `pads.mode_select` is "cycle"; with the LC6000's four
    /// buttons it does nothing.
    mutating func cycle() -> [Send] {
        guard pads.modeSelect == .cycle else { return [] }
        mode = mode.next
        return [.releasePads]
    }

    /// Pad `index` (0-based, so hot cue `index + 1`) pressed, in the current mode.
    func pressed(_ index: Int, _ facts: Facts) -> [Send] {
        let cue = Int32(index + 1)
        switch mode {
        case .hotCue:
            guard index < Self.syndicateCues else { return [] }
            // Shift on a stopped deck (#358): go to the cue without playing.
            if facts.shift, !facts.playing, !facts.playPending { return [.cueJump(index + 1)] }
            return [.hold(index, "HotCue", press: [.int(cue), .int(1)], release: [.int(cue), .int(0)])]
        case .roll:
            // The profile's roll sizes (#196); a pad past the list does nothing.
            guard rollSizes.indices.contains(index) else { return [] }
            return [.hold(index, "SlipLoop/" + rollSizes[index], press: [.int(1)], release: [.int(0)])]
        case .loop:
            guard index < Self.syndicateCues else { return [] }
            return [.osc("SetCueLoop", .int(cue))]
        case .slicer: return []
        }
    }

    /// Pad `index` released: whatever it held lets go.
    func released(_ index: Int) -> [Send] { [.release(index)] }

    /// The pad a note plays, and on a profile with notes per mode (#225) the mode that note belongs to.
    func pad(for note: Int) -> (index: Int, mode: PadMode?)? {
        guard let modeNotes = pads.modeNotes else { return padNotes.firstIndex(of: note).map { ($0, nil) } }
        for mode in PadMode.allCases {
            if let index = notes(for: mode, modeNotes).firstIndex(of: note) { return (index, mode) }
        }
        return nil
    }

    /// A pad note pressed: its pad, after switching to the note's own mode (#225) when that's another one, which lets
    /// held pads go as a mode button does. Nil for a note that isn't a pad's.
    mutating func press(note: Int) -> (index: Int, sends: [Send])? {
        guard let (index, noteMode) = pad(for: note) else { return nil }
        guard let noteMode, noteMode != mode else { return (index, []) }
        mode = noteMode
        return (index, [.releasePads])
    }

    /// The notes the pads send and light in `mode`: that mode's list (#225), or `notes.pads` for every mode.
    func notes(for mode: PadMode) -> [Int] {
        guard let modeNotes = pads.modeNotes else { return padNotes }
        return notes(for: mode, modeNotes)
    }

    private func notes(for mode: PadMode, _ modeNotes: Mapping.Pads.ModeNotes) -> [Int] {
        switch mode {
        case .hotCue: modeNotes.hotcue
        case .roll: modeNotes.roll
        case .loop: modeNotes.loop
        case .slicer: modeNotes.slicer
        }
    }

    /// Every note of every mode's own list (#225): the ones to darken when they're not the current mode's.
    var allModeNotes: [Int] {
        guard let modeNotes = pads.modeNotes else { return [] }
        return modeNotes.hotcue + modeNotes.roll + modeNotes.loop + modeNotes.slicer
    }
}

/// The Bridge's LED caches (#383 slice 5d): the last velocity sent to each LED, so an unchanged LED is never sent
/// twice. Pads on their own channel (#224) are kept apart: a pad's note can be a button's on another channel. The
/// Bridge keeps the output; this says whether a write goes out.
struct LEDCache: Equatable, Sendable {
    struct Lit: Equatable, Sendable {
        var note: Int
        var velocity: UInt8
    }

    private var buttons: [Int: UInt8] = [:]
    private var pads: [Int: UInt8] = [:]

    /// Whether `velocity` on `note` should go out: true (and remembered) when it isn't what the LED shows already.
    mutating func write(_ note: Int, _ velocity: UInt8, onPads: Bool) -> Bool {
        if onPads {
            guard pads[note] != velocity else { return false }
            pads[note] = velocity
        } else {
            guard buttons[note] != velocity else { return false }
            buttons[note] = velocity
        }
        return true
    }

    /// Forget what every LED shows, so the next paint sends them all.
    mutating func flush() {
        buttons.removeAll()
        pads.removeAll()
    }

    /// What one cache shows, in note order.
    func shown(onPads: Bool) -> [Lit] {
        (onPads ? pads : buttons).keys.sorted().map { Lit(note: $0, velocity: (onPads ? pads : buttons)[$0] ?? 0) }
    }
}
