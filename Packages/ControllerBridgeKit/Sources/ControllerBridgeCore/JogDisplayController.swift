// The jog display controller (#384): which deck the LC6000's jog display shows, each deck's needle, and the driver
// behind JogDisplayPort, from plain values per controller entry. The Coordinator only forwards to it; it reads no
// Bridge internals, only each Bridge's DeckFacts (#383).

final class JogDisplayController {
    private let clock: any Clock
    /// Each entry's needle: its deck's own phase in the bar (#165).
    private var needles: [Int: JogMarker] = [:]
    /// What each entry's facts said last, to see a new BarRamp and a deck that stops.
    private var lastRamp: [Int: DeckFacts.BarRamp] = [:]
    private var lastPlaying: [Int: Bool] = [:]
    /// Syndicate's master tempo, for a deck whose own BPM isn't known yet.
    private(set) var masterBPM: Double?
    /// The master clock's beat on time (#720): from Syndicate's beat messages and master BPM, so the display's beat
    /// goes when it's due, not when a message happens to arrive.
    private var beatClock = BeatClock()
    /// The LC6000's jog display, when the app found its WD port.
    private var driver: JogDisplayDriver?
    /// Settings' "Show the deck on the jog display" (ADR-0005): while off, nothing goes to the display's ports, not
    /// even the hello.
    private(set) var enabled = false
    /// The deck the preview follows with no controller connected (#221): the user's pick, 1-4; nil, the first loaded.
    private(set) var previewDeck: Int?
    /// When the next live update is due: a schedule 1/`liveRate` apart (#558), so a send that lands late on a tick
    /// doesn't push the next one back. After a stall it restarts from now, with no burst to catch up.
    private var nextLiveDue: Double?
    /// The live cadence (#592, #605): the needle, the meter and the phase go together, 50 times a second, every 20 ms.
    /// 20 ms is two of the app's 10 ms ticks, so every step is the same (a rate that beats against the tick reads as
    /// judder), and together they cost the chip one redraw (dfw_tick parses what's waiting, then draws once). #592's
    /// stall at this rate was the unit's power, not the rate: with the adapter in, 2 min 37 s at 50 a second had no
    /// gap and no disconnect (#605).
    static let liveRate = 50.0
    /// The chip's redraw budget (#592, #605): what the cadence asks of it at most, at ~14 ms a redraw (#563). The live
    /// cadence (50) plus the master beat (at most 3 a second at 180 BPM) and the time (1 a second, when the shown second
    /// changes) is 54: 54 × 0.014 = 76% of the chip's time. The chip's USB control path runs in its own interrupt, so
    /// drawing can't starve it. Nothing enforces this; the redraw test checks the cadence keeps to it.
    static let redrawBudget = 54
    /// Each mixer channel's meter (#461), through its ballistics (#582): what the drawn meter and the preview show.
    private var meters: [Int: MeterBallistics] = [:]
    /// The deck whose meter went out last: a switch sends the new one's at once.
    private var lastMeterDeck: Int?

    init(clock: any Clock) {
        self.clock = clock
    }

    /// Syndicate's header feedback: the master tempo (and, for the ring, the master beat).
    func feedback(_ message: OSCMessage) {
        let address = message.address.lowercased()
        // A mixer channel's meter (#461), for the drawn display's level meter.
        if let channel = (1...4).first(where: { address.hasSuffix("/mixer/ch\($0)/meter") }),
           let level = message.arguments.first?.number {
            // On the meter's dB scale (#582), so the fall runs evenly down the drawn arc.
            meters[channel, default: MeterBallistics()].sample(MeterScale.position(level), at: clock.now)
        }
        if address.hasSuffix("/header/bpm"), let bpm = message.arguments.first?.number, bpm > 0 {
            masterBPM = bpm
            beatClock.setTempo(bpm)
        }
        // The master clock is the lit ring segment, the same on every deck (the user's pick).
        if address.hasSuffix("/header/clock"), let beat = message.arguments.first?.wholeNumber, (1...4).contains(beat) {
            beatClock.edge(beat, at: clock.now)
            masterBeatTick()
        }
    }

    /// The beat clock's beat now to the display; the driver sends only a change.
    private func masterBeatTick() {
        let beat = beatClock.beat(at: clock.now)
        if beat != 0 { driver?.masterBeat(beat) }
    }

    /// A deck's mixer meter as the drawn meter shows it, 0-1; 0 before its channel reports (#617).
    func meterLevel(_ deck: Int) -> Double { meters[deck]?.level ?? 0 }

    /// The unit's display firmware (#425), kept for a driver attached later.
    private var displayFirmware = DisplayFirmware.denon
    func setDisplayFirmware(_ firmware: DisplayFirmware) {
        displayFirmware = firmware
        driver?.displayFirmware = firmware
    }

    /// Says goodbye, so the next refresh says hello again (#429).
    func disconnect() {
        driver?.disconnect()
    }

    /// The app is quitting (#600): our logo stays on a drawing unit.
    func quit() {
        driver?.quit()
    }

    /// Everything sent so far gone out, before the app exits (#600).
    func flush() {
        driver?.flush()
    }

    /// Whether the driver has said hello to a unit.
    var connected: Bool { driver?.connected ?? false }

    /// Syndicate's feedback stopped or came back (#464).
    func setStale(_ stale: Bool) {
        driver?.setStale(stale)
    }

    /// Whether the unit draws the screen itself now (#461).
    var drawing: Bool { if case .customDrawn = driver?.found { true } else { false } }

    /// The display firmware found on the unit (#456).
    var found: DisplayFound? { driver?.found }

    /// Whether the display is taking images now (#422).
    var uploading: Bool { driver?.uploading ?? false }

    /// Drives the display from now on.
    func attach(_ driver: JogDisplayDriver) {
        self.driver = driver
        driver.displayFirmware = displayFirmware
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    /// How the key is written (#590): every content, so the images, the drawn display's key text and the preview.
    private(set) var keyDisplay = KeyNotation.traditional
    func setKeyDisplay(_ notation: KeyNotation) {
        keyDisplay = notation
    }

    func setPreviewDeck(_ deck: Int?) {
        previewDeck = deck
    }

    /// The top panel answered the hello (#606); whether a re-sent one was answered.
    @discardableResult
    func helloAnswered() -> Bool { driver?.helloAnswered() ?? false }

    /// A message from the display's WD port: the unit's answers to an upload.
    func reply(_ bytes: [UInt8]) {
        driver?.reply(bytes)
    }

    /// The display shows the deck in front; every deck is previewed for the simulator (#221). With none connected,
    /// nothing reaches a unit (goodbye), but the preview follows a deck from Syndicate. Off, or with no WD port to show
    /// on (#305), nothing reaches the unit either.
    func refresh(_ entries: [Entry], color: (Int) -> [Int]?) {
        guard let driver else { return }
        func content(_ index: Int) -> JogDisplayContent {
            let facts = entries[index].facts, track = facts.track
            return JogDisplayContent(deck: facts.deck, color: color(facts.deck) ?? [255, 255, 255], title: track?.title,
                                     artist: track?.artist, key: track.map { keyDisplay.shown($0.key) }, bpm: track?.bpm,
                                     playerType: track?.playerType)
        }
        for index in entries.indices { driver.preview(content(index)) }
        guard let first = entries.indices.first(where: { entries[$0].connected }) else {
            driver.disconnect()
            guard let index = Self.front(entries, previewDeck: previewDeck) else { return }
            return driver.show(content(index))
        }
        let front = Self.front(entries, previewDeck: previewDeck) ?? first
        if enabled, driver.attached { driver.connect() } else { driver.disconnect() }
        driver.show(content(front))
        // Every other deck's images stay on the unit too (#424), so a switch to it needs no upload.
        guard driver.connected else { return }
        for index in entries.indices where index != front && entries[index].facts.deck != entries[front].facts.deck {
            driver.keep(content(index))
        }
    }

    /// The driver's timers, then the needles (every playing deck's for the simulator, the deck in front's to the unit,
    /// at most 30 a second) and the play light: 127 while playing, blinking every half-second while loaded and paused.
    func tick(_ entries: [Entry]) {
        // Every channel's ballistics move on each tick (#582); the front deck's go to the unit, all to the preview and
        // the display feed (#617), which needs them with no unit too.
        for channel in meters.keys { meters[channel]?.step(at: clock.now) }
        guard let driver else { return }
        driver.tick()
        masterBeatTick()
        let front = Self.front(entries, previewDeck: previewDeck)
        // The live cadence (#592): the needle, then the meter and the phase below, in the same tick.
        let live = nextLiveDue.map { clock.now >= $0 - 1e-9 } ?? true
        if live {
            for index in entries.indices where entries[index].facts.playing {
                let needle = needle(index, at: clock.now)
                driver.deckMarker(deck: entries[index].facts.deck, needle)
                if index == front { driver.marker(needle) }
            }
            let period = 1 / Self.liveRate
            let next = (nextLiveDue ?? clock.now) + period
            nextLiveDue = next > clock.now ? next : clock.now + period
        }
        // Every deck's play state for the simulator, from Syndicate's Playing (#317), not the blinking light below.
        for entry in entries { driver.deckPlaying(deck: entry.facts.deck, entry.facts.playing) }
        drawnPreviewTick(entries, driver: driver)
        guard let front else { return }
        let facts = entries[front].facts
        meterTick(deck: facts.deck, live: live, driver: driver)
        timeTick(facts, driver: driver)
        phaseTick(entries, front: front, live: live, driver: driver)
        driver.deckState(loaded: facts.loaded, playing: facts.playing, pending: facts.playPending, loop: facts.looping,
                         cue: facts.cueHeld)
        driver.playLight(facts.playing || (facts.loaded && Int((clock.now / 0.5).rounded(.down)) % 2 == 0))
    }

    /// The deck in front's meter to the drawn display, at most 30 times a second; the peak falls to the level once
    /// it has held. Nothing until its channel has reported.
    /// The time message (#460): at most 4 a second, so a scrub doesn't flood the wire; a change held back goes
    /// once the quarter second is up. Steady play changes it once a second, so a seek goes at once. A new deck in
    /// front isn't held: its time lands with its deck message.
    static let timeRate = 4.0
    private var lastTimeSent: Double?, lastTimeDeck: Int?
    private func timeTick(_ facts: DeckFacts, driver: JogDisplayDriver) {
        if facts.deck == lastTimeDeck, let sent = lastTimeSent, clock.now - sent < 1 / Self.timeRate - 1e-9 { return }
        lastTimeDeck = facts.deck
        if driver.time(.time(elapsed: facts.position, length: facts.duration)) { lastTimeSent = clock.now }
    }

    /// Each deck's phase value (#462), from its PhaseOffset with DrawnPhase's hysteresis and wrap guard, kept for every
    /// deck so a switch shows the new one's at once.
    private var phases: [Int: DrawnPhase] = [:]
    private var lastPhaseDeck: Int?

    /// The deck in front's phase to the drawn display, at most 30 times a second (Syndicate sends about 45 during a
    /// nudge); a held-back change goes once the interval is up, and a deck switch at once.
    private func phaseTick(_ entries: [Entry], front: Int, live: Bool, driver: JogDisplayDriver) {
        var value = DrawnPhase.unknown
        for (index, entry) in entries.enumerated() {
            let facts = entry.facts
            let deckValue = phases[facts.deck, default: DrawnPhase()].value(offset: facts.phaseOffset, playing: facts.playing)
            if index == front { value = deckValue }
        }
        let deck = entries[front].facts.deck
        // On the live cadence, or at once for a new deck.
        guard live || deck != lastPhaseDeck else { return }
        lastPhaseDeck = deck
        driver.phase(value)
    }

    /// Every deck's drawn preview (#465): its flags, needle, meter, phase and time, as the unit would get them.
    private func drawnPreviewTick(_ entries: [Entry], driver: JogDisplayDriver) {
        for (index, entry) in entries.enumerated() {
            let facts = entry.facts
            var flags: DrawnDisplay.State = []
            for (flag, on) in [(DrawnDisplay.State.loaded, facts.loaded), (.playing, facts.playing),
                               (.playPending, facts.playPending), (.loopOn, facts.looping), (.cueHeld, facts.cueHeld)] where on {
                flags.insert(flag)
            }
            func scaled(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 127).rounded()) }
            let meter = meters[facts.deck].map { (level: scaled($0.level), peak: scaled($0.peak)) }
            driver.drawnPreview(deck: facts.deck, flags: flags, needle: needle(index, at: clock.now), meter: meter,
                                phase: phases[facts.deck]?.lastValue ?? DrawnPhase.unknown,
                                time: .time(elapsed: facts.position, length: facts.duration))
        }
    }

    private func meterTick(deck: Int, live: Bool, driver: JogDisplayDriver) {
        // A channel that hasn't reported shows an empty meter, not the last deck's (#461).
        guard let meter = meters[deck] else {
            lastMeterDeck = deck
            driver.meter(level: 0, peak: 0)
            return
        }
        // On the live cadence, or at once for a new deck.
        guard live || deck != lastMeterDeck else { return }
        lastMeterDeck = deck
        func scaled(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 127).rounded()) }
        driver.meter(level: scaled(meter.level), peak: scaled(meter.peak))
    }

    /// Each entry's facts, after Syndicate's feedback: a deck that stops keeps its needle where it is, and a new
    /// BarRamp sets it, running on at the deck's tempo while it plays (the platter never moves it, #388).
    func observe(_ entries: [Entry]) {
        for (index, entry) in entries.enumerated() {
            let facts = entry.facts
            if lastPlaying[index] == true, !facts.playing {
                needles[index]?.freeze(at: clock.now)
                // The master deck stopped: so did the master clock, at once (#720, as the panel's #660). Another
                // deck's pause says nothing about it.
                if facts.master { beatClock.stop() }
            }
            lastPlaying[index] = facts.playing
            if let ramp = facts.barRamp, ramp != lastRamp[index] {
                lastRamp[index] = ramp
                let bpm = facts.playing ? facts.bpm ?? masterBPM ?? 120 : 0
                needles[index, default: JogMarker()].ramp(ramp.phase, bpm: bpm, at: ramp.at)
            }
        }
    }

    /// An entry's needle as pitch bend at `time`.
    func needle(_ index: Int, at time: Double) -> Int {
        (needles[index] ?? JogMarker()).pitchBend(at: time)
    }

    /// What the controller knows of one controller entry, in the Coordinator's order.
    struct Entry: Equatable {
        /// The entry's MIDI input is open.
        var connected: Bool
        /// Its profile excludes a WD port that's present: the display is its (#305).
        var ownsDisplay: Bool
        /// It's the active layer of its controller.
        var activeLayer: Bool
        var facts: DeckFacts
    }

    /// The entry whose deck the display shows. Connected: an entry that owns the display comes first, then the active
    /// layer, else the first. With none connected, the preview's (#221): the picked deck's, else the first loaded one's,
    /// else the first.
    static func front(_ entries: [Entry], previewDeck: Int?) -> Int? {
        let connected = entries.indices.filter { entries[$0].connected }
        if !connected.isEmpty {
            let owners = connected.filter { entries[$0].ownsDisplay }
            let candidates = owners.isEmpty ? connected : owners
            return candidates.first { entries[$0].activeLayer } ?? candidates.first
        }
        if let pick = previewDeck, let index = entries.indices.first(where: { entries[$0].facts.deck == pick }) { return index }
        return entries.indices.first { entries[$0].facts.loaded } ?? entries.indices.first
    }
}
