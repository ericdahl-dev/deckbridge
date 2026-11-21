/// Runs the Bridges (one per controller) against the MIDI system, the OSC sender, a clock and a log.
///
/// Not thread-safe on purpose: the app confines it to one serial consumer that feeds it MIDI, feedback and ticks in
/// order. Tests call it directly.
public final class Coordinator {
    private let midiSystem: any MIDISystem
    private let osc: any OSCSender
    private let clock: any Clock
    private let baseLog: any LogSink
    /// Every log line also goes to the trace, when there is one (#395).
    private var log: any LogSink { TracingLog(base: baseLog, trace: trace) }
    /// The debug trace (#395): set by a Debug build before start(); nil in Release, at no cost.
    public var trace: TraceSink? {
        didSet {
            (osc as? OSCTap)?.onTrace = trace.map { sink in { [weak self] message in self?.traceOSC(.oscOut, message, sink) } }
            for index in controllers.indices { controllers[index].bridge.trace = trace }
            displayFeed.trace = trace
        }
    }
    /// Streaming OSC, both ways, at most 5 a second per address in the trace.
    private var traceSampler = StreamSampler()
    /// Where a finished meter capture's CSV goes (#582): the app's Debug build writes it to its Logs folder.
    public var meterCaptureSink: (@Sendable (String) -> Void)?
    /// The meter capture running, if any.
    var meterCapture: MeterCapture?
    /// The jog display's last restart after a port took data again (#595), and a restart held back until the back-off
    /// ends; the back-off said once a stretch.
    private var jogRestartedAt: Double?
    private var jogRestartDue: Double?
    private var jogBackoffSaid = false
    static let jogRestartBackoff = 3.0
    private var controllers: [Controller]
    /// The controller profiles a device can match.
    private var profiles: [ControllerProfile]
    /// Unmatched devices already logged, so a device-list change doesn't log them again.
    private var loggedUnmatched: Set<MIDIEndpoint.ID> = []
    /// Devices matching more than one profile, already logged.
    private var loggedAmbiguous: Set<MIDIEndpoint.ID> = []
    private var bridges: [Bridge] { controllers.map(\.bridge) }
    /// Profiles chosen by hand per device name (#200), as profile ids.
    private var profileChoices: [String: String] = [:]

    /// The profile for a device: the one chosen for it by hand, if that profile exists, else the one its name matches.
    private func resolvedProfile(_ deviceName: String) -> ControllerProfile? {
        if let id = profileChoices[deviceName], let chosen = profiles.first(where: { $0.id == id }) { return chosen }
        return ControllerProfile.matching(deviceName, in: profiles)
    }

    /// The profiles chosen by hand per device name (#200). A controller whose device now resolves to another profile,
    /// or to none, reconnects; one with no device tries again, so a device no profile named can now run.
    public func setProfileChoices(_ choices: [String: String]) {
        guard choices != profileChoices else { return }
        profileChoices = choices
        var resync = false
        for index in controllers.indices {
            if let source = controllers[index].source {
                guard resolvedProfile(source.name)?.id != controllers[index].profile.id else { continue }
                disconnect(index, reason: .deviceChanged)
            }
            if connect(index) {
                controllers[index].bridge.start()
                resync = true
            }
        }
        refreshDevices()
        if resync { requestResend() }
    }

    /// The source the capture window (#186) is recording, whose MIDI drives nothing meanwhile.
    private var capturing: MIDIEndpoint.ID?
    /// Deck colors from Syndicate's palette, the defaults until one arrives (#123).
    private var syndicateDeckColors = DeckColors.defaults
    /// The decks whose palette slot Syndicate has sent, so their `syndicateDeckColors` are its own, not the defaults
    /// (#617). Slots may come one per message.
    private var paletteHeard: Set<Int> = []
    /// Syndicate's last master clock beat, 1-4, and when it came: the display feed's beat (#617).
    private var masterBeat: (beat: Int, at: Double)?
    /// Each deck's phase rule for the display feed (#617), with its own in-phase and wrap memory.
    private var feedPhase: [Int: DrawnPhase] = [:]
    /// Settings' deck colors (#123): follow Syndicate, or the custom colors.
    private var followSyndicateDeckColors = true
    private var customDeckColors = DeckColors.defaults
    /// The deck colors in use: the ring's, and the app's badges through the status.
    var deckColors: DeckColors { followSyndicateDeckColors ? syndicateDeckColors : customDeckColors }

    /// A Bridge for a controller, with the deck colors in use.
    /// Settings' ring color mapping (#151).
    private var ringColors = RingColors.vivid
    /// Settings (#530): pads and ring in exact RGB through Denon's color message, where the profile lists them. Off,
    /// every color goes through the 64-color table. The app turns it on from its setting.
    private var colorMessages = false
    /// Settings (#532): the color-message LEDs' brightness, in percent.
    private var lightBrightness = 100

    private func makeBridge(_ mapping: Mapping) -> Bridge {
        let bridge = Bridge(mapping: mapping, osc: osc, clock: clock)
        bridge.trace = trace
        bridge.deckColors = deckColors
        bridge.ringColors = ringColors
        bridge.colorMessages = colorMessages
        bridge.lightBrightness = lightBrightness
        bridge.stripFaderSetting = stripFaderSetting
        return bridge
    }

    private var loggedBlackDecks: Set<Int> = []

    /// Logs once per deck when Syndicate's color for it is black, which DeckColors replaces with the default.
    private func noteBlackSlot(_ numbers: [Int]) -> [Int] {
        if numbers.count >= 4, let deck = DeckColors.deck(forSlot: numbers[0]), DeckColors.isBlack(numbers[1...3]) {
            if loggedBlackDecks.insert(deck).inserted {
                log.log("Syndicate's deck \(deck) color is black, which the LC6000's ring can't show; using the default")
            }
        }
        return numbers
    }

    /// Gives every Bridge the deck colors in use; each repaints its ring.
    private func applyDeckColors() {
        status.deckColors = deckColors
        for bridge in bridges { bridge.setDeckColors(deckColors) }
        updateJogDisplay()
    }

    /// Feedback liveness, Resend timing and the subscription verdict (#21, #150, #385).
    private var health = FeedbackHealth(quiet: 0, answerWindow: 0)

    /// Set while the Diagnostics window is open (#26); nil otherwise, so nothing is built for it during a set.
    /// The LED sweep in progress: when it started, its steps and the next one to send.
    private var sweep: (start: Double, steps: [LEDSweep.Step], next: Int)?

    public var diagnostics: ((DiagnosticEvent) -> Void)? {
        didSet { (osc as? OSCTap)?.onSend = diagnostics.map { sink in { sink(.oscOut($0)) } } }
    }
    /// Settings' LEDs switch, kept so a Bridge rebuilt for another profile honors it.
    private var ledsEnabled = true

    /// What the menu shows. The app copies it after each call.
    /// The profile the first controller runs: the bundled one, or an imported mapping (#24). The demo runs it (#98).
    public var runningProfile: ControllerProfile { controllers[0].profile }

    public private(set) var status: CoordinatorStatus

    /// A Bridge and the devices it is connected to.
    private struct Controller {
        var bridge: Bridge
        /// The profile the bridge runs, chosen by the connected device's name.
        var profile: ControllerProfile
        var source: MIDIEndpoint?
        /// The unique id of the last source this controller used, so a replug finds the same unit first.
        var knownSourceID: MIDIEndpoint.ID?
        /// The devices picked in Settings (#19). Nil is automatic: the first device a profile matches.
        var chosenInput: MIDIEndpoint.ID?
        var chosenOutput: MIDIEndpoint.ID?
        /// The MIDI channel picked in Settings (#25), 1-16, or nil for the profile's.
        var channel: Int?
        /// One of the deck layers of a controller that follows its own layers (#79): it shares the unit with the
        /// other layers, on its own channel.
        var followsLayers = false
        /// The entry's own setting (#133): it follows layers whenever its profile has them.
        var wantsLayers = false
        /// The destination its LEDs go to, once open.
        var destination: MIDIEndpoint?
    }

    /// One controller, whose profile is chosen by the name of the device that connects. Until one does, it runs the
    /// first profile. `profiles` must not be empty.
    public init(profiles: [ControllerProfile], midi: any MIDISystem, osc: any OSCSender, clock: any Clock, log: any LogSink) {
        precondition(!profiles.isEmpty, "A Coordinator needs at least one controller profile")
        self.midiSystem = midi
        // Every Bridge sends through the tap, so the OSC log sees what goes out while Diagnostics is open.
        self.osc = OSCTap(osc)
        self.clock = clock
        self.baseLog = log
        self.profiles = profiles
        let first = profiles[0]
        controllers = [Controller(bridge: Bridge(mapping: first.mapping, osc: self.osc, clock: clock), profile: first)]
        status = CoordinatorStatus(controllers: [ControllerStatus(deck: first.mapping.deck.number, connected: false)])
    }

    /// One controller running `mapping`, matched to a device whose name contains `mapping.midi.input`.
    public convenience init(mapping: Mapping, midi: any MIDISystem, osc: any OSCSender, clock: any Clock, log: any LogSink) {
        let profile = ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: [mapping.midi.input], mapping: mapping)
        self.init(profiles: [profile], midi: midi, osc: osc, clock: clock, log: log)
    }

    // MARK: Jog display (#165)

    /// The jog display (#384): the deck in front, the needles and the driver. The Coordinator only forwards to it.
    private lazy var jogController = JogDisplayController(clock: clock)

    /// Turns the jog display on (hello, then the deck in front) or off (goodbye, then nothing).
    public func setJogDisplay(enabled: Bool) {
        jogController.setEnabled(enabled)
        status.requiredSubscriptions = requiredSubscriptions
        updateJogDisplay()
    }

    /// Settings' display firmware (#425): how many image slots the unit's display will show.
    public func setDisplayFirmware(_ firmware: DisplayFirmware) {
        jogController.setDisplayFirmware(firmware)
        holdRing()
    }

    /// Settings' Key display (#590): the jog display, its images and the preview write the key this way from now on.
    public func setKeyDisplay(_ notation: KeyNotation) {
        jogController.setKeyDisplay(notation)
        updateJogDisplay()
    }

    /// Picks the deck the jog display preview follows while no controller is connected; nil, the first loaded deck.
    public func setJogPreviewDeck(_ deck: Int?) {
        jogController.setPreviewDeck(deck)
        updateJogDisplay()
    }

    /// Drives the jog display from now on: it says hello and shows the deck in front once a controller is connected.
    public func attachJogDisplay(_ driver: JogDisplayDriver) {
        jogController.attach(driver)
        updateJogDisplay()
    }

    /// The top panel's answer to the hello (#606, #439: `9F 37 7F`), from the controller that owns the display.
    private func jogHelloAnswered(source: MIDIEndpoint.ID) {
        let entries = jogEntries
        guard entries.indices.contains(where: { entries[$0].ownsDisplay && controllers[$0].source?.id == source }) else { return }
        // A re-sent hello that landed: the unit came back with its LEDs cleared, so they're painted again, as after the
        // first hello (#426). Once per connect: the driver reports it only for the first answer.
        guard jogController.helloAnswered() else { return }
        trace?(.jogDisplay, "jog display: a re-sent hello was answered: the LEDs painted again")
        for (index, entry) in entries.enumerated() where entry.ownsDisplay && controllers[index].bridge.layerShown {
            controllers[index].bridge.repaintLEDs()
        }
    }

    /// A message from the jog display's WD port: the unit's answers to an upload.
    public func jogDisplayReply(_ bytes: [UInt8]) {
        jogController.reply(bytes)
        holdRing()
    }

    /// The ring of the controller that owns the display stays dark while the display uploads (#422).
    private func holdRing() {
        // Only a change is written: this runs every tick.
        if status.displayFound != jogController.found {
            status.displayFound = jogController.found
            status.requiredSubscriptions = requiredSubscriptions   // drawn mode asks for the meter (#461)
        }
        let held = jogController.uploading
        for (index, entry) in jogEntries.enumerated() where entry.ownsDisplay {
            controllers[index].bridge.ringHeld = held
        }
    }

    /// What the jog display knows of each controller entry: plain values and the Bridge's DeckFacts (#383).
    private var jogEntries: [JogDisplayController.Entry] {
        // A connected controller whose profile excludes a WD port that's present owns the display (#305).
        let names = midiSystem.sources.map { $0.name.lowercased() }
        return controllers.indices.map { index in
            var facts = controllers[index].bridge.facts
            facts.deck = status.controllers[index].deck
            let owns = controllers[index].profile.excludeHints.contains { hint in names.contains { $0.contains(hint.lowercased()) } }
            return JogDisplayController.Entry(connected: controllers[index].source != nil, ownsDisplay: owns,
                                              activeLayer: status.controllers[index].activeLayer, facts: facts)
        }
    }

    private func updateJogDisplay() {
        updateDisplayFeed()
        let wasConnected = jogController.connected
        jogController.refresh(jogEntries, color: { self.deckColors[$0] })
        holdRing()
        // The hello goes to the Controller port, where the LEDs are: paint them again after it (#426).
        guard !wasConnected, jogController.connected else { return }
        for (index, entry) in jogEntries.enumerated() where entry.ownsDisplay && controllers[index].bridge.layerShown {
            controllers[index].bridge.repaintLEDs()
        }
    }

    // MARK: Display feed (#490, #616)

    /// The deck in front, as plain OSC, for a display such as the panel. Off until the setting turns it on.
    private let displayFeed = DisplayFeed()
    /// The same feed over the USB cable (#667): a destination of its own, with its own switch and its own snapshot.
    private let cableFeed = DisplayFeed()

    /// Where the cable's feed goes: the app's sender for the panel's serial port.
    public func attachCableFeed(_ sender: any OSCSender) {
        cableFeed.attach(sender)
        updateDisplayFeed()
    }

    /// The panel's serial port opened (plugged in, or the switch turned on): the full snapshot on the cable.
    public func cableFeedReady() {
        cableFeed.resend(at: clock.now)
        updateDisplayFeed()
    }

    /// Where the display feed goes: the app's UDP destination for the display.
    public func attachDisplayFeed(_ sender: any OSCSender) {
        displayFeed.attach(sender)
        updateDisplayFeed()
    }

    /// Settings' display feed: on sends the deck in front at once.
    public func setDisplayFeed(_ settings: DisplayFeedSettings) {
        displayFeed.set(settings, at: clock.now)
        cableFeed.set(settings.overTheCable, at: clock.now)
        status.requiredSubscriptions = requiredSubscriptions
        updateDisplayFeed()
    }

    /// Takes the display feed and its setting from the real Coordinator, for the demo's while it runs (#625). The
    /// destination is already open, so the first snapshot goes out once the demo's deck is known.
    public func takeDisplayFeed(from real: Coordinator) {
        guard let (sender, settings, greeted) = real.displayFeed.release() else { return }
        displayFeed.attach(sender)
        displayFeed.carryGreeting(greeted)
        displayFeed.set(settings, at: clock.now)
        status.requiredSubscriptions = requiredSubscriptions
        displayFeedReady()
    }

    /// Takes the display feed back from the demo's Coordinator when it ends (#625), with a full snapshot. Its own
    /// setting stays: a change made during the demo waited for the real Coordinator and is already applied.
    public func takeBackDisplayFeed(from demo: Coordinator) {
        guard let (sender, _, greeted) = demo.displayFeed.release() else { return }
        displayFeed.attach(sender)
        displayFeed.carryGreeting(greeted)
        displayFeedReady()
    }

    /// The display's destination opened: the full snapshot again, since what went before it was dropped.
    public func displayFeedReady() {
        displayFeed.resend(at: clock.now)
        updateDisplayFeed()
    }

    /// The feed's deck: the jog display's deck in front (the active layer; with no controller, the preview's deck),
    /// whether or not the jog display is on.
    /// Whether LoopInfo's seconds are the track's (so its BPM gives the beats) or the deck's at its live tempo. No
    /// capture settles it yet (#617): this one line flips it, and loopLengthAtShiftedTempo with it.
    static let loopSecondsAreTrackTime = true

    /// The loop's length in beats, unrounded: a display rounds for itself (#617).
    private static func loopBeats(_ facts: DeckFacts, trackBPM: Double, liveBPM: Double) -> Double {
        let bpm = loopSecondsAreTrackTime && trackBPM > 0 ? trackBPM : liveBPM
        guard let seconds = facts.loopSeconds, bpm > 0 else { return 0 }
        return seconds * bpm / 60
    }

    /// Whole seconds as the drawn display's time message counts them: down, 0 for none or below.
    private static func wholeSeconds(_ value: Double?) -> Int {
        guard let value, value > 0, value.isFinite else { return 0 }
        return Int(min(value, Double(Int32.max)))
    }

    /// Where the deck is through its track, 0-1; 0 with no length known.
    private static func progress(_ facts: DeckFacts) -> Double {
        guard let duration = facts.duration, duration > 0, let position = facts.position, position.isFinite else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// The deck's phase as the drawn display's rule gives it (#462), on the feed's scale: 0.5 in phase, 0 a half beat
    /// behind, 1 a half beat ahead; -1 unknown.
    private func feedPhase(_ facts: DeckFacts) -> Double {
        let value = feedPhase[facts.deck, default: DrawnPhase()].value(offset: facts.phaseOffset, playing: facts.playing)
        return value == DrawnPhase.unknown ? -1 : 0.5 + Double(value) / 16384
    }

    private func updateDisplayFeed() {
        let feeds = [displayFeed, cableFeed].filter(\.on)
        guard !feeds.isEmpty else { return }
        let entries = jogEntries
        guard let front = JogDisplayController.front(entries, previewDeck: jogController.previewDeck) else {
            for feed in feeds { feed.update(nil, at: clock.now) }
            return
        }
        let facts = entries[front].facts
        let deck = displayFeedDeck(facts), known = displayFeedKnown(facts)
        for feed in feeds { feed.update(deck, known: known, at: clock.now) }
    }

    /// Syndicate has answered for the deck: its colors (unless DeckBridge's own are used) and whether it's loaded,
    /// with its track when it is.
    private func displayFeedKnown(_ facts: DeckFacts) -> Bool {
        let colorKnown = paletteHeard.contains(facts.deck) || !followSyndicateDeckColors
        let trackKnown = !facts.loaded || facts.track != nil
        return colorKnown && facts.loadedHeard && trackKnown
    }

    /// What the display feed shows of a deck. Plain statements, not one expression: CI's type checker times out on
    /// long nested ones.
    private func displayFeedDeck(_ facts: DeckFacts) -> DisplayFeed.Deck {
        var deck = DisplayFeed.Deck(number: facts.deck, color: deckColors[facts.deck] ?? [255, 255, 255])
        // Not loaded is the empty state (#617): nothing of a track, even one TrackInfo named before Loaded.
        guard facts.loaded else { return deck }
        let trackBPM = facts.track?.bpm ?? 0
        var bpm = 0.0
        if let live = facts.bpm { bpm = live } else if trackBPM > 0 { bpm = trackBPM }
        deck.loaded = true
        deck.title = facts.track?.title ?? ""
        deck.artist = facts.track?.artist ?? ""
        if let track = facts.track { deck.key = jogController.keyDisplay.shown(track.key) }
        deck.bpm = bpm
        if trackBPM > 0, bpm > 0 { deck.tempo = (bpm / trackBPM - 1) * 100 }
        deck.playing = facts.playing
        deck.cue = facts.cueHeld
        deck.sync = facts.synced
        deck.master = facts.master
        deck.loop = facts.looping
        if facts.looping { deck.loopLength = Self.loopBeats(facts, trackBPM: trackBPM, liveBPM: bpm) }
        // The master clock, as the ring's beat pulse: none once it's been quiet for the Bridge's timeout.
        if let master = masterBeat, clock.now - master.at <= Bridge.clockTimeout {
            deck.beat = master.beat
            // Its BPM (#674), only while the clock runs, so a display never times beats off a stopped clock.
            deck.clockBpm = jogController.masterBPM ?? 0
        }
        let elapsed = Self.wholeSeconds(facts.position)
        deck.elapsed = elapsed
        if facts.duration != nil { deck.remaining = max(0, Self.wholeSeconds(facts.duration) - elapsed) }
        deck.progress = Self.progress(facts)
        deck.phase = feedPhase(facts)
        deck.level = jogController.meterLevel(facts.deck)
        return deck
    }

    /// Opens each controller's ports, asks Syndicate for its state and paints the LEDs. Starting with no controller
    /// connected is not an error: it connects when it appears.
    ///
    /// With the saved `controllers` and LEDs switch (#105), every controller is set up first and only then connected,
    /// so it never touches a device, deck or LED the user didn't choose. Nil keeps what's set: the automatic start at
    /// launch, and the current controllers and LEDs switch on a restart (after the demo).
    public func start(controllers entries: [ControllerSettings]? = nil, ledsEnabled: Bool? = nil) {
        if let ledsEnabled { self.ledsEnabled = ledsEnabled }
        if let entries, !entries.isEmpty {
            for (index, entry) in entries.enumerated() { configure(index, as: entry) }
        }
        for bridge in bridges { bridge.setLEDsEnabled(self.ledsEnabled) }
        status.requiredSubscriptions = requiredSubscriptions
        refreshDevices()
        for index in controllers.indices {
            if !connect(index) {
                log.log("No controller matching \"\(controllers[index].bridge.mapping.midi.input)\" yet")
            }
            controllers[index].bridge.start()
        }
        updateJogDisplay()
        requestResend()
    }

    /// The MIDI devices changed. Re-reads them, connecting controllers that appeared. `removed` is every endpoint
    /// CoreMIDI removed since the last change, even one already back (#429): a unit power-cycled quickly comes back
    /// with the same ids but in standalone state, so its controllers reconnect as if unplugged and plugged in again.
    public func devicesChanged(removed: Set<MIDIEndpoint.ID> = []) {
        refreshDevices()
        // The display's WD port removed and back: the unit forgot it was a host, so goodbye now and hello below.
        let hints = controllers.flatMap(\.profile.excludeHints).map { $0.lowercased() }
        if midiSystem.sources.contains(where: { source in
            removed.contains(source.id) && hints.contains { source.name.lowercased().contains($0) }
        }) {
            jogController.disconnect()
        }
        for index in controllers.indices {
            if let source = controllers[index].source {
                if !midiSystem.sources.contains(where: { $0.id == source.id }) || removed.contains(source.id) {
                    disconnect(index, reason: .unplugged)
                } else if controllers[index].bridge.output == nil {
                    // Its input connected before its output port appeared (#148): open the port now and paint into it.
                    openOutput(index, for: source, profile: controllers[index].profile)
                    if controllers[index].bridge.output != nil { controllers[index].bridge.repaintLEDs() }
                }
            }
            if controllers[index].source == nil, connect(index) {
                controllers[index].bridge.start()
                requestResend()
            }
        }
        disconnectFailedOutputs()
        updateJogDisplay()
    }

    /// Reading from a source failed, such as a reconnect that couldn't attach. Counts as that controller's unplug.
    public func inputFailed(source: MIDIEndpoint.ID) {
        for index in controllers.indices where controllers[index].source?.id == source {
            disconnect(index, reason: .inputFailed)
        }
    }

    /// Releases everything the controller held, exactly once, and closes its ports.
    private func disconnect(_ index: Int, reason: DisconnectReason) {
        guard let source = controllers[index].source else { return }
        if capturing == source.id { capturing = nil }
        controllers[index].bridge.ledsCaptured = false
        let bridge = controllers[index].bridge
        bridge.releaseAll()
        controllers[index].source = nil
        let destination = controllers[index].destination
        controllers[index].destination = nil
        // Another controller on the same device, on another channel (#25), keeps it open.
        if !controllers.contains(where: { $0.source?.id == source.id }) { midiSystem.disconnect(source: source) }
        if destination == nil || !controllers.contains(where: { $0.destination?.id == destination?.id }) { bridge.output?.close() }
        bridge.output = nil
        status.controllers[index].profile = nil
        status.controllers[index].device = nil
        status.controllers[index].lastDisconnect = reason
        let detail: String? = switch reason {
        case .sendFailed: "MIDI send failed"
        case .inputFailed: "MIDI input failed"
        case .unplugged, .deviceChanged, .removed, .stopped: nil
        }
        report(index, "Disconnected \(source.name)" + (detail.map { " (\($0))" } ?? ""))
        updateJogDisplay()
    }

    /// Whether two controllers are layers of one unit: both follow layers, on different channels. Two following
    /// entries on one channel would put two decks on one layer, so they don't share.
    private func sharesLayers(_ a: Int, with b: Int) -> Bool {
        guard controllers[a].followsLayers, controllers[b].followsLayers else { return false }
        let channelA = controllers[a].bridge.mapping.midi.channel, channelB = controllers[b].bridge.mapping.midi.channel
        guard channelA != channelB, let source = controllers[b].source else { return channelA != channelB }
        // Another layer already on this unit with my channel means this unit's layer is taken.
        return !controllers.indices.contains { $0 != a && controllers[$0].source?.id == source.id
            && controllers[$0].followsLayers && controllers[$0].bridge.mapping.midi.channel == channelA }
    }

    /// Opens the controller's ports if a matching device is present. Returns whether its input is connected.
    private func connect(_ index: Int) -> Bool {
        let sources = midiSystem.sources
        let source: MIDIEndpoint?
        if let chosen = controllers[index].chosenInput {
            source = sources.first { $0.id == chosen }
        } else {
            // Automatic: a unit another controller already has stays with it, except that a controller following its
            // own layers shares its unit with its other layers, each on its own channel (#79).
            let claimed = Set(controllers.indices.filter { $0 != index && !sharesLayers(index, with: $0) }
                .compactMap { controllers[$0].source?.id })
            let free = sources.filter { !claimed.contains($0.id) }
            // The last device it ran on comes first, while a profile still resolves for it (#200: not after a choice
            // made by hand for it is taken back).
            let known = controllers[index].knownSourceID.flatMap { id in free.first { $0.id == id && resolvedProfile($0.name) != nil } }
            source = known ?? free.first { resolvedProfile($0.name) != nil }
        }
        guard let source else { return false }
        // A device picked in Settings runs even if no profile names it: then it keeps the current profile.
        let matchedProfile = resolvedProfile(source.name)
        guard let profile = matchedProfile ?? (controllers[index].chosenInput != nil ? controllers[index].profile : nil) else {
            return false
        }
        if profile != controllers[index].profile {
            controllers[index].profile = profile
            controllers[index].bridge = makeBridge(profile, for: index)
        }
        let bridge = controllers[index].bridge
        do {
            if !controllers.contains(where: { $0.source?.id == source.id }) { try midiSystem.connect(source: source) }
        } catch {
            log.log("Couldn't open MIDI input \(source.name): \(error)")
            return false
        }
        controllers[index].source = source
        controllers[index].knownSourceID = source.id
        status.controllers[index].profile = profile.name
        status.controllers[index].device = source.name
        status.controllers[index].lastProfile = profile.name
        openOutput(index, for: source, profile: profile)
        report(index, "Connected \(source.name)")
        return true
    }

    /// What each output's lights show (#554), one for all the layers that share it.
    private var shownByOutput: [MIDIEndpoint.ID: LEDShown] = [:]
    private func shown(for output: MIDIEndpoint.ID) -> LEDShown {
        if let shown = shownByOutput[output] { return shown }
        let shown = LEDShown()
        shownByOutput[output] = shown
        return shown
    }

    /// Opens the LED output for a connected controller: the chosen one, else the port named like its input, else
    /// the mapping's hint, never a port the profile excludes. Logs where the LEDs go, or that they have nowhere to go.
    private func openOutput(_ index: Int, for source: MIDIEndpoint, profile: ControllerProfile) {
        let bridge = controllers[index].bridge
        let destinations = midiSystem.destinations
        let chosenOutput = controllers[index].chosenOutput.flatMap { id in destinations.first { $0.id == id } }
        // Layers of one unit share its port both ways (#79): a destination another layer has isn't taken from this one.
        let taken = Set(controllers.indices.filter { $0 != index && !sharesLayers(index, with: $0) }
            .compactMap { controllers[$0].destination?.id })
        let freeDestinations = controllers[index].chosenInput == nil ? destinations.filter { !taken.contains($0.id) } : destinations
        // The LEDs go back to the port the controls came from: same name first, then the name hint (#99).
        let sameName = freeDestinations.first { $0.name == source.name }
        // Never a port the profile excludes, such as the LC6000's jog display (WD): its "LC6000" matches the hint too.
        let allowed = freeDestinations.filter { destination in
            !profile.excludeHints.contains { destination.name.lowercased().contains($0.lowercased()) }
        }
        if let destination = chosenOutput ?? sameName ?? Self.match(allowed, bridge.mapping.midi.output) {
            do {
                let opened = try midiSystem.openOutput(destination: destination)
                let leds = bridge.mapping
                bridge.output = trace.map {
                    TracingOutput(inner: opened, name: destination.name, trace: $0, ledName: { leds.ledName(note: Int($0)) })
                } ?? opened
                // Layers sharing a unit open the same port: say it once.
                if controllers[index].destination?.id != destination.id,
                   !controllers.contains(where: { $0.destination?.id == destination.id }) {
                    log.log("LEDs go to \(destination.name)")
                }
                controllers[index].destination = destination
                // Layers on one port share what its lights show (#554).
                bridge.shown = shown(for: destination.id)
            } catch {
                log.log("Couldn't open MIDI output \(destination.name): \(error)")
            }
        } else {
            log.log("No LED output found for \(source.name), so its LEDs stay dark")
        }
    }

    /// Lists every MIDI source with the profile it matches. A source that matches none is listed, not bridged.
    private func refreshDevices() {
        status.devices = midiSystem.sources.map { source in
            if let profile = resolvedProfile(source.name) {
                if profileChoices[source.name] == profile.id { return DeviceStatus(name: source.name, profile: profile.name, note: nil) }
                let names = ControllerProfile.candidates(source.name, in: profiles).map(\.profile.name)
                if names.count > 1, loggedAmbiguous.insert(source.id).inserted {
                    log.log("\(source.name) matches \(names.joined(separator: " and ")); using \(profile.name), whose hint is longest.")
                }
                return DeviceStatus(name: source.name, profile: profile.name, note: nil)
            }
            let lowered = source.name.lowercased()
            if let owner = profiles.first(where: { $0.excludeHints.contains { lowered.contains($0.lowercased()) } }) {
                return DeviceStatus(
                    name: source.name, profile: nil, note: "\(source.name) is another port of the \(owner.name).", partOf: owner.name
                )
            }
            let note = "No controller profile matches \(source.name), so it isn't bridged."
            if loggedUnmatched.insert(source.id).inserted { log.log(note) }
            return DeviceStatus(name: source.name, profile: nil, note: note)
        }
    }

    private func report(_ index: Int, _ event: String) {
        log.log(event)
        status.controllers[index].connected = controllers[index].source != nil
        status.controllers[index].outputOpen = controllers[index].bridge.output != nil
        status.controllers[index].lastEvent = event
    }

    /// Another DJ app took the LC6000 as its host, or let go (#333). The detector that calls this comes after the #333
    /// spike; until then only tests do. Logged once each way, for Diagnostics.
    func otherHostChanged(_ present: Bool) {
        guard present != status.otherHost else { return }
        status.otherHost = present
        log.log(present ? "Another DJ app is using the LC6000 as its host" : "The other DJ app let go of the LC6000")
    }

    /// Starts or ends the capture of a source (#186). While it's captured, its MIDI drives neither Syndicate nor its
    /// LEDs, though its layers are still followed. Starting releases what its controllers held, like an unplug, forgets
    /// the jog's position, so the first message after only seeds it, and re-arms the pitch pickup. `nil`, an unplug or
    /// stop ends the capture.
    public func setCapture(source: MIDIEndpoint.ID?) {
        // The controller given back paints its LEDs again, from the state now.
        for controller in controllers where controller.bridge.ledsCaptured && controller.source?.id != source {
            controller.bridge.ledsCaptured = false
            controller.bridge.repaintLEDs()
        }
        capturing = source
        guard let source else { return }
        for controller in controllers where controller.source?.id == source {
            controller.bridge.ledsCaptured = true
            controller.bridge.releaseAll()
            controller.bridge.jogModule.forgetPlatter()
            // The capture sweeps the pitch fader, so it waits for pickup after, instead of jumping the tempo.
            controller.bridge.rearmPickup()
            controller.bridge.rearmMixer()   // and the mixer's faders and knobs (#321)
        }
    }

    /// Releases everything held in Syndicate. Safe to call again: a second call sends nothing.
    public func stop() {
        for index in controllers.indices {
            controllers[index].bridge.releaseAll()
            disconnect(index, reason: .stopped)
        }
    }

    /// The app is quitting (#600): as stop, but a drawing jog display keeps our logo rather than Denon's screen. Then
    /// it waits for the sends to go out: they leave on a queue (#552), and the app exits after this.
    public func quit() {
        jogController.quit()
        stop()
        // Every controller gone says the goodbye already; this covers a display with none connected.
        jogController.disconnect()
        jogController.flush()
        displayFeedGoodbye()
    }

    /// The display feed's goodbye, last, and its sends flushed (#651): on quit, from whichever Coordinator holds the feed
    /// (the demo's while it runs).
    public func displayFeedGoodbye() {
        for feed in [displayFeed, cableFeed] { feed.goodbye() }
        for feed in [displayFeed, cableFeed] { feed.flush() }
    }

    /// The Mac is about to sleep: release everything held, since the controller may be gone on wake.
    public func willSleep() {
        for bridge in bridges { bridge.releaseAll() }
    }

    /// The Mac woke: the devices may have changed while it slept.
    public func didWake() {
        devicesChanged()
    }

    /// Runs timers, such as releasing a jog nudge after the wheel stops. The app calls it about every 10 ms.
    public func tick() {
        finishMeterCapture()
        if let due = jogRestartDue, clock.now >= due - 1e-9 { restartJogDisplay() }
        settleLayer()
        runSweep()
        for bridge in bridges { bridge.tick() }
        jogController.tick(jogEntries)
        // Any change no other call sent, within a tick; only changes go out.
        updateDisplayFeed()
        holdRing()
        checkLiveness()
        disconnectFailedOutputs()
    }

    /// Starts a meter capture of `seconds` from now (#582).
    func startMeterCapture(seconds: Double) { meterCapture = MeterCapture(start: clock.now, seconds: seconds) }

    /// A meter capture whose time is up goes to its sink, once.
    private func finishMeterCapture() {
        guard let capture = meterCapture, capture.done(at: clock.now) else { return }
        meterCapture = nil
        meterCaptureSink?(capture.csv)
    }

    /// The first endpoint whose name contains `wanted`, ignoring case.
    private static func match(_ endpoints: [MIDIEndpoint], _ wanted: String) -> MIDIEndpoint? {
        endpoints.first { $0.name.lowercased().contains(wanted.lowercased()) }
    }

    /// A MIDI message from a source. Only the controller connected to that source handles it.
    public func midi(_ event: MIDIEvent, source: MIDIEndpoint.ID) {
        let mapping = (controllers.first { $0.source?.id == source } ?? controllers[0]).bridge.mapping
        if case .noteOn(15, 55, 127) = event { jogHelloAnswered(source: source) }
        // Notes the controller sends on its own, such as the LC6000's idle heartbeat (#103), reach nothing.
        if case .noteOn(_, let note, _) = event, mapping.midi.ignoreNotes.contains(Int(note)) { return }
        if case .noteOff(_, let note, _) = event, mapping.midi.ignoreNotes.contains(Int(note)) { return }
        if let diagnostics {
            diagnostics(.midiIn(event, label: mapping.monitorName(for: event), at: clock.now))
        }
        if let trace {
            let port = controllers.first { $0.source?.id == source }?.source?.name ?? "source \(source)"
            trace(.midiIn, "\(port) ch\(Int(event.channel) + 1) \(event.midoText) \(mapping.monitorName(for: event))")
        }
        let (routed, onlyLayer) = layerHandover(event, source: source)
        // Captured (#186): the layers still follow the unit, so the right one is active after; nothing else runs.
        if source == capturing { return }
        for index in controllers.indices where controllers[index].source?.id == source
            && (onlyLayer == nil || index == onlyLayer || !controllers[index].followsLayers) {
            controllers[index].bridge.handle(routed)
            for notice in controllers[index].bridge.notices { log.log(notice) }
            controllers[index].bridge.notices.removeAll()
        }
        // A held CUE is the feed's (#617).
        updateDisplayFeed()
        disconnectFailedOutputs()
    }

    /// Units seen sending controls on a layer's own channel (#79): the LC6000's multi-channel state. Others are in
    /// the normal state, every control on ch1.
    private var multiChannelUnits: Set<MIDIEndpoint.ID> = []

    /// The controller's own deck layers (#79), as the LC6000 really behaves (the CoS's captures):
    /// - note 51 at 127 on channel N makes layer N active; its note 51 at 0 always comes on ch1 and means nothing;
    /// - in its normal state every control stays on ch1, so ch1 controls go to the active layer's deck;
    /// - in the other state seen (controls on the layer's own channel), a control on channel N goes to deck N and
    ///   makes layer N active.
    /// - a pad on a layer's own pad channel (#323) brings that layer to the front; on a pad channel several layers share
    ///   (pads.channel only), it plays the layer in front. Neither is the multi-channel state.
    /// Returns the event as the layers should see it: a ch1 control re-addressed to the active layer's channel; and,
    /// for a pad, the one layer that handles it.
    /// `layerHandover`'s `only` for an event no layer handles: only controllers that don't follow layers get it.
    private static let noLayer = -1

    private func layerHandover(_ event: MIDIEvent, source: MIDIEndpoint.ID) -> (MIDIEvent, only: Int?) {
        let layers = controllers.indices.filter { controllers[$0].source?.id == source && controllers[$0].followsLayers }
        guard let first = layers.first else { return (event, nil) }
        let (channel, note, velocity): (UInt8, UInt8?, UInt8) = switch event {
        case .noteOn(let c, let n, let v): (c, n, v)
        case .noteOff(let c, let n, _): (c, n, 0)
        case .controlChange(let c, _, let v): (c, nil, v)
        }
        let layerChannel = { (index: Int) in self.controllers[index].bridge.mapping.midi.channel }
        let current = layers.first { status.controllers[$0].activeLayer } ?? first
        if let note, Int(note) == controllers[first].bridge.mapping.midi.layerNote {
            if velocity > 0, let target = layers.first(where: { layerChannel($0) == Int(channel) + 1 }) {
                if target != current {
                    activateLayer(target, leaving: current, among: layers, multiChannel: multiChannelUnits.contains(source))
                } else {
                    // Deck select back onto the same layer (#426): the unit's deck-select mode cleared its LEDs.
                    controllers[target].bridge.repaintLEDs()
                }
            }
            return (event, nil)
        }
        // A plain deck select (#420): the bridge steps to the next layer itself; the unit's own layer stays put.
        if let note, Int(note) == controllers[first].bridge.mapping.notes.buttons["deck_select"] {
            if velocity > 0, let at = layers.firstIndex(of: current) {
                let target = layers[(at + 1) % layers.count]
                // The bridge's own step: the unit's selected deck, and so the one channel it takes note-ons on, stays
                // (agent2's #481 reading). That's the channel deck select itself came on, so the new layer paints there
                // at once, not on its own channel, which the unit drops; and the unit didn't touch its lights, so only
                // those that differ go (#554).
                activateLayer(target, leaving: current, among: layers, multiChannel: multiChannelUnits.contains(source),
                              unitCleared: false, unitChannel: channel)
                // Its light (#477) flashes full on the layer it stepped to, and goes back to idle on release.
                controllers[target].bridge.pressLit("deck_select", true)
            } else if velocity == 0 {
                controllers[current].bridge.pressLit("deck_select", false)
            }
            // Lit here; no layer handles the note itself, or a hidden one would keep it held.
            return (event, Self.noLayer)
        }
        let onPads = layers.filter {
            let bridge = controllers[$0].bridge
            return (bridge.padChannel == channel && bridge.padChannel != bridge.channel) || bridge.shiftedPadChannel == channel
        }
        if let padLayer = onPads.count == 1 ? onPads.first : onPads.contains(current) ? current : onPads.first {
            if padLayer != current { activateLayer(padLayer, leaving: current, among: layers, multiChannel: multiChannelUnits.contains(source)) }
            return (event, padLayer)
        }
        if channel == 0 {
            // The normal state: controls on ch1. The active layer's LEDs go out where its controls are.
            if layerChannel(current) != 1 { multiChannelUnits.remove(source) }
            setLEDChannel(0, for: current)
            return (layerChannel(current) == 1 ? event : event.onChannel(UInt8(layerChannel(current) - 1)), nil)
        }
        // Controls on a layer's own channel: that layer is the one in use, and the unit is in its multi-channel state.
        multiChannelUnits.insert(source)
        guard let target = layers.first(where: { layerChannel($0) == Int(channel) + 1 }) else { return (event, nil) }
        if target != current { activateLayer(target, leaving: current, among: layers, multiChannel: true) }
        status.controllers[target].activeLayer = true
        setLEDChannel(nil, for: target)
        return (event, nil)
    }

    /// One handover: the layer left releases what it held and stops writing LEDs; the new one becomes the only active
    /// layer and waits for the shared fader's pickup. Its LEDs go out where the unit's controls come: ch1 in the
    /// normal state, the layer's own channel in the multi-channel state.
    /// `unitCleared`: the unit made the change (its layer note, a control or pad on a layer's channel) and its
    /// deck-select mode cleared its lights (#426), so the new layer paints every one; the bridge's own deck select step
    /// (#420) paints only the lights that differ from what the unit shows (#554).
    /// `unitChannel`: the channel the unit takes LEDs on, when the bridge stepped on its own (#420) and the unit's
    /// selected deck didn't move; nil when the unit made the change (its channel is then the layer's, or ch1 in the
    /// normal state).
    private func activateLayer(_ target: Int, leaving current: Int, among layers: [Int], multiChannel: Bool,
                               unitCleared: Bool = true, unitChannel: UInt8? = nil) {
        if current != target { controllers[current].bridge.releaseAll() }
        for index in layers where index != target {
            status.controllers[index].activeLayer = false
            controllers[index].bridge.layerShown = false
        }
        status.controllers[target].activeLayer = true
        let bridge = controllers[target].bridge
        if let unitChannel {
            bridge.ledChannel = unitChannel == bridge.channel ? nil : unitChannel
        } else {
            bridge.ledChannel = multiChannel || bridge.mapping.midi.channel == 1 ? nil : 0
        }
        // The one pitch fader stayed where it was, and the unit doesn't send it again: the new layer takes its
        // position, so the pitch arrows point the right way at once (#475).
        if current != target { controllers[target].bridge.takeFader(from: controllers[current].bridge) }
        controllers[target].bridge.rearmPickup()
        // A lone step shows at once. Steps that follow within LayerSettle.interval wait until the steps settle
        // (#428), then show the last layer once: a burst of steps is two repaints, not one per step.
        let rapid = pendingLayer != nil || lastLayerStep.map { clock.now - $0 < LayerSettle.interval } ?? false
        lastLayerStep = clock.now
        if rapid {
            pendingLayer = target
            pendingLayerFull = pendingLayerFull || unitCleared
            pendingLayerAt = clock.now + LayerSettle.interval
            return
        }
        // The display first, so its uploads hold the ring before the repaint could light it (#422).
        updateJogDisplay()
        controllers[target].bridge.showLayer(full: unitCleared)
    }

    /// The layer whose LEDs and display wait for the steps to settle, and when they're due; and whether any of the
    /// steps it settles had the unit clear its lights.
    private var pendingLayer: Int?
    private var pendingLayerAt = 0.0
    private var pendingLayerFull = false
    /// When the last layer step came.
    private var lastLayerStep: Double?

    /// Shows the settled layer: the display first, so its uploads hold the ring before the repaint could light it
    /// (#422); then every LED once.
    private func settleLayer() {
        guard let target = pendingLayer, clock.now >= pendingLayerAt - 1e-9 else { return }
        pendingLayer = nil
        let full = pendingLayerFull
        pendingLayerFull = false
        guard controllers.indices.contains(target), status.controllers[target].activeLayer else { return }
        updateJogDisplay()
        controllers[target].bridge.showLayer(full: full)
    }

    /// Where a layer's LEDs go; repaints there if it moved.
    private func setLEDChannel(_ channel: UInt8?, for index: Int) {
        let bridge = controllers[index].bridge
        let effective = channel == 0 && bridge.mapping.midi.channel == 1 ? nil : channel
        guard bridge.ledChannel != effective else { return }
        bridge.ledChannel = effective
        if bridge.layerShown { bridge.becameActiveLayer() }
    }

    /// An OSC feedback message from Syndicate. One listener fans out to every Bridge.
    public func feedback(_ message: OSCMessage) {
        if meterCapture != nil {
            meterCapture?.record(message, at: clock.now)
            finishMeterCapture()
        }
        // Syndicate's deck colors are cue palette slots 1, 3, 5 and 7 (#123).
        // Several slots may come in one message (OSC arrays, flattened): one group of four per slot.
        if message.address.lowercased().hasSuffix("/colorpalette") {
            let numbers = message.arguments.compactMap(\.wholeNumber)
            var colors = syndicateDeckColors
            for start in stride(from: 0, to: numbers.count - 3, by: 4) {
                if let deck = DeckColors.deck(forSlot: numbers[start]) { paletteHeard.insert(deck) }
                if let updated = colors.updated(byPalette: noteBlackSlot(Array(numbers[start..<(start + 4)]))) { colors = updated }
            }
            if colors != syndicateDeckColors {
                syndicateDeckColors = colors
                applyDeckColors()
            }
        }
        if message.address.lowercased().hasSuffix("/header/clock"), let beat = message.arguments.first?.wholeNumber,
           (1...4).contains(beat) {
            masterBeat = (beat, clock.now)
        }
        diagnostics?(.oscIn(message))
        if let trace { traceOSC(.oscIn, message, trace) }
        jogController.feedback(message)
        feedbackArrived(message)
        for bridge in bridges { bridge.handle(message) }
        jogController.observe(jogEntries)
        for index in controllers.indices { status.controllers[index].master = controllers[index].bridge.isMaster }
        // What the display shows may have changed (a load, a key or BPM change); equal content draws nothing.
        if message.address.lowercased().hasSuffix("/trackinfo") || message.address.lowercased().hasSuffix("/loaded") {
            updateJogDisplay()
        }
        // Any of the feed's fields may have changed; only what did goes out.
        updateDisplayFeed()
        disconnectFailedOutputs()
    }

    /// A failed MIDI send means the controller is gone, even before CoreMIDI says so.
    private func disconnectFailedOutputs() {
        for index in controllers.indices where controllers[index].bridge.outputFailed {
            disconnect(index, reason: .sendFailed)
        }
    }

    // MARK: Feedback liveness (#21)

    // Syndicate sends feedback only when a value changes, so after a quiet spell the bridge asks for a resend: a live
    // Syndicate answers with every subscribed value, and always ColorPalette (user guide §14.10).

    /// The OSC settings are shared by every controller; the first one's mapping holds them until Settings (#19).
    private var oscSettings: Mapping.OSC { controllers[0].bridge.mapping.osc }

    /// The health module, with the current OSC settings' windows (Settings may change them).
    private func checkHealth(_ step: (inout FeedbackHealth, Double) -> FeedbackHealth.Output) {
        health.quiet = Double(oscSettings.feedbackQuietMs) / 1000
        health.answerWindow = Double(oscSettings.feedbackAnswerMs) / 1000
        let output = step(&health, clock.now)
        status.feedback = health.feedback
        jogController.setStale(health.feedback == .stale)
        if output.deckDataProven { status.noDeckData = false }
        if let verdict = output.verdict {
            status.noDeckData = verdict.noDeckData
            status.missingSubscriptions = verdict.missing
        }
        switch output.event {
        case .back:
            log.log("Syndicate feedback is back")
            for bridge in bridges { bridge.start() }
        case .stopped: feedbackStopped()
        case nil: break
        }
        if output.resend { sendResend() }
    }

    private func feedbackArrived(_ message: OSCMessage) {
        checkHealth { $0.messageArrived(message, at: $1) }
    }

    private func checkLiveness() {
        let required = requiredSubscriptions
        checkHealth { $0.tick(at: $1, required: required) }
    }

    /// What every controller's profile needs, in the guide's order (#211).
    private var requiredSubscriptions: [Subscription] {
        var needed = Set(bridges.flatMap { Subscription.required(for: $0.mapping) })
        // The jog needle reads the deck's BarRamp (#165): asked for only while the display is on.
        if jogController.enabled { needed.insert(.barRamp) }
        // The drawn display's level meter reads the mixer's Meter (#461): asked for only while the unit draws.
        if jogController.drawing { needed.insert(.mixerMeter) }
        // Its phase rule reads the deck's PhaseOffset (#462): asked for only while the unit draws.
        if jogController.drawing { needed.insert(.phaseOffset) }
        // The display feed's level and phase read them too (#617).
        if displayFeed.enabled || cableFeed.enabled { needed.formUnion([.mixerMeter, .phaseOffset]) }
        // Shift + Needle Drop's relative fader move starts from Syndicate's level (#609).
        if bridges.contains(where: { $0.stripFaderMode == .relative }) { needed.insert(.mixerVolume) }
        return Subscription.allCases.filter(needed.contains)
    }

    /// Syndicate didn't answer: show idle for its state until it's back.
    private func feedbackStopped() {
        let event = "Syndicate feedback stopped"
        status.lastDropout = event
        log.log(event)
        for bridge in bridges { bridge.clearSyndicateState() }
    }

    /// Settings (#19): the controller drives another deck from now on. Held controls are released on the old one,
    /// then the controller resyncs.
    public func setDeck(_ deck: Int, controller index: Int) {
        guard controllers.indices.contains(index), controllers[index].bridge.mapping.deck.number != deck else { return }
        controllers[index].bridge.switchDeck(to: deck)
        status.controllers[index].deck = deck
        updateDisplayFeed()
        requestResend()
        disconnectFailedOutputs()
    }

    /// Settings (#19): the controller uses these devices from now on, or nil for automatic. Held controls are
    /// released and the old ports closed first, then the controller connects and resyncs.
    public func setDevices(input: MIDIEndpoint?, output: MIDIEndpoint?, controller index: Int) {
        guard controllers.indices.contains(index) else { return }
        controllers[index].chosenInput = input?.id
        controllers[index].chosenOutput = output?.id
        controllers[index].knownSourceID = input?.id
        disconnect(index, reason: .deviceChanged)
        if connect(index) {
            controllers[index].bridge.start()
            requestResend()
        }
        disconnectFailedOutputs()
    }

    /// Settings (#25): the controller entries, one per controller. Existing controllers take their entry's changes;
    /// new entries connect and resync.
    public func setControllers(_ entries: [ControllerSettings]) {
        // At least one controller always runs, so start() and the status have someone to show.
        guard !entries.isEmpty else { return }
        while controllers.count > entries.count { removeLastController() }
        for index in entries.indices {
            if index < controllers.count {
                update(index, to: entries[index])
            } else {
                addController(entries[index])
            }
        }
        // The entries may have dropped and reconnected the controller: the display follows again (#165).
        updateJogDisplay()
    }

    // Kept as separate small functions: Xcode 26.6's optimizer crashed (CopyPropagation) on one loop doing all three.

    private func removeLastController() {
        let last = controllers.count - 1
        controllers[last].bridge.releaseAll()
        disconnect(last, reason: .removed)
        controllers.removeLast()
        status.controllers.removeLast()
    }

    /// Sets controller `index` up as `entry` says, adding it if it's new, without connecting anything: start (#105)
    /// connects them all afterwards.
    private func configure(_ index: Int, as entry: ControllerSettings) {
        let profile = profiles[0]
        if index == controllers.count {
            controllers.append(Controller(bridge: makeBridge( profile.mapping), profile: profile))
            status.controllers.append(ControllerStatus(deck: entry.deck, connected: false))
        }
        status.controllers[index].deck = entry.deck
        controllers[index].channel = entry.channel
        controllers[index].wantsLayers = entry.followLayers == true
        deriveFollowing(index)
        controllers[index].chosenInput = entry.input?.id
        controllers[index].chosenOutput = entry.output?.id
        controllers[index].knownSourceID = entry.input?.id
        controllers[index].bridge = makeBridge(controllers[index].profile, for: index)
        // A device chosen in Settings: until it connects, the panel says WAITING for it (#91), as after a change.
        if entry.input != nil { status.controllers[index].lastDisconnect = .deviceChanged }
    }

    private func addController(_ entry: ControllerSettings) {
        let first = profiles[0]
        let index = controllers.count
        status.controllers.append(ControllerStatus(deck: entry.deck, connected: false))
        var controller = Controller(bridge: makeBridge( first.mapping), profile: first)
        controller.channel = entry.channel
        controller.wantsLayers = entry.followLayers == true
        controllers.append(controller)
        deriveFollowing(index)
        controllers[index].bridge = makeBridge(first, for: index)
        setDevices(input: entry.input, output: entry.output, controller: index)
    }

    private func update(_ index: Int, to entry: ControllerSettings) {
        controllers[index].wantsLayers = entry.followLayers == true
        deriveFollowing(index)
        setDeck(entry.deck, controller: index)
        if entry.channel != controllers[index].channel {
            controllers[index].channel = entry.channel
            setChannel(index)
        }
        let devicesChanged = entry.input?.id != controllers[index].chosenInput || entry.output?.id != controllers[index].chosenOutput
        if devicesChanged { setDevices(input: entry.input, output: entry.output, controller: index) }
    }

    /// Rebuilds the controller's Bridge on its new channel: held controls are released first, the ports stay open.
    private func setChannel(_ index: Int) {
        let old = controllers[index].bridge
        old.releaseAll()
        let bridge = makeBridge(controllers[index].profile, for: index)
        bridge.output = old.output
        bridge.shown = old.shown
        controllers[index].bridge = bridge
        guard controllers[index].source != nil else { return }
        bridge.start()
        requestResend()
    }

    /// A Bridge running `profile` with this controller's settings: its deck, channel and the LEDs switch.
    private func makeBridge(_ profile: ControllerProfile, for index: Int) -> Bridge {
        var mapping = profile.mapping
        // The deck and channel are settings, not part of the profile.
        mapping.deck.number = status.controllers[index].deck
        if let channel = controllers[index].channel {
            mapping.midi.channel = channel
            // A deck layer's pads may have their own channel (#224). Once any layer sets one, a layer that doesn't has its
            // pads on its own channel: the top-level pads.channel is only for profiles whose layers set none (#323).
            let layers = profile.mapping.midi.layers
            if let layer = layers.first(where: { $0.channel == channel }), layer.padChannel != nil || layers.contains(where: { $0.padChannel != nil }) {
                mapping.pads.channel = layer.padChannel
            }
            // The same for the Shift pads' channel (#324).
            if let layer = layers.first(where: { $0.channel == channel }),
               layer.shiftedPadChannel != nil || layers.contains(where: { $0.shiftedPadChannel != nil }) {
                mapping.pads.shiftedChannel = layer.shiftedPadChannel
            }
        }
        let bridge = makeBridge( mapping)
        bridge.setLEDsEnabled(ledsEnabled)
        bridge.layerShown = layerInFront(index, channel: mapping.midi.channel, layers: profile.mapping.midi.layers)
        return bridge
    }

    /// Whether this controller's LEDs are the ones the unit shows (#79): any controller that doesn't follow layers;
    /// the active layer; or, before any handover, the profile's first layer.
    private func layerInFront(_ index: Int, channel: Int, layers: [Mapping.Layer]) -> Bool {
        guard controllers[index].followsLayers else { return true }
        if status.controllers[index].activeLayer { return true }
        let anyActive = controllers.indices.contains { $0 != index && controllers[$0].followsLayers && status.controllers[$0].activeLayer }
        return !anyActive && channel == layers.first?.channel
    }

    /// An imported mapping (#24): these profiles replace the current ones. A controller whose profile changed releases
    /// its held controls first, then runs the new one on the same ports with its settings (deck, channel, LEDs) kept,
    /// and the bridge resyncs once.
    public func setProfiles(_ newProfiles: [ControllerProfile]) {
        guard !newProfiles.isEmpty else { return }
        profiles = newProfiles
        var resync = false
        for index in controllers.indices where swapProfile(index, from: newProfiles) { resync = true }
        if resync { requestResend() }
        disconnectFailedOutputs()
    }

    /// Follows layers when the entry asks to and its profile has them (#133). A profile without layers can't be
    /// followed: the entry falls back to its own deck, with no layer active (#115).
    private func deriveFollowing(_ index: Int) {
        let follows = controllers[index].wantsLayers && !controllers[index].profile.mapping.midi.layers.isEmpty
        controllers[index].followsLayers = follows
        status.controllers[index].followsLayers = follows
        if !follows { status.controllers[index].activeLayer = false }
    }

    /// One controller's part of `setProfiles`: returns whether it is connected and now runs a changed profile.
    /// Its own function, as Xcode 26.6's optimizer crashed on loops that mutate `controllers` inline (#65).
    private func swapProfile(_ index: Int, from newProfiles: [ControllerProfile]) -> Bool {
        guard let updated = newProfiles.first(where: { $0.id == controllers[index].profile.id }),
              updated != controllers[index].profile else { return false }
        let old = controllers[index].bridge
        old.releaseAll()
        let wasFollowing = controllers[index].followsLayers
        controllers[index].profile = updated
        deriveFollowing(index)
        let bridge = makeBridge(updated, for: index)
        bridge.output = old.output
        bridge.shown = old.shown
        bridge.carrySyndicateState(from: old)
        bridge.carryOwnState(from: old)
        // The active layer's LEDs keep going where the unit's controls come from (#79).
        if wasFollowing, controllers[index].followsLayers { bridge.ledChannel = old.ledChannel }
        controllers[index].bridge = bridge
        guard controllers[index].source != nil else { return false }
        status.controllers[index].profile = updated.name
        bridge.start(stale: old.feedbackStale)
        return true
    }

    /// A MIDI port took data again after it had stopped (#552): what was dropped meanwhile is lost, so each layer in
    /// front paints every light again. The drawn display's heartbeat already brings the screen back.
    public func repaintAfterRecovery() {
        for controller in controllers where controller.source != nil && controller.bridge.layerShown {
            controller.bridge.repaintLEDs()
        }
        disconnectFailedOutputs()
    }

    /// A jog display port takes data again (#595): start the display over, as after a replug; what was dropped
    /// meanwhile is worthless. A port that wedges again at once is restarted at most every `jogRestartBackoff`.
    func jogDisplayRecovered() {
        if let last = jogRestartedAt, clock.now - last < Self.jogRestartBackoff - 1e-9 {
            jogRestartDue = last + Self.jogRestartBackoff
            if !jogBackoffSaid {
                jogBackoffSaid = true
                let text = "jog display port took data again within \(Self.jogRestartBackoff) s of a restart: " +
                    "restarting it at most every \(Self.jogRestartBackoff) s"
                log.log(text)
                trace?(.jogDisplay, text)
            }
            return
        }
        jogBackoffSaid = false
        restartJogDisplay()
    }

    private func restartJogDisplay() {
        jogRestartedAt = clock.now
        jogRestartDue = nil
        jogController.disconnect()
        updateJogDisplay()
    }

    /// Asks Syndicate to resend its state (#84): the OSC destination opened late, so what was sent before was dropped.
    public func resync() {
        // A Resend still "waiting" went out before there was anywhere to send it.
        checkHealth { FeedbackHealth.Output(resend: $0.resync(at: $1)) }
    }

    /// Settings' deck colors (#123): the ring repaints, and the status carries them to the badges.
    public func setDeckColors(followSyndicate: Bool, custom: DeckColors) {
        followSyndicateDeckColors = followSyndicate
        customDeckColors = custom
        applyDeckColors()
        disconnectFailedOutputs()
    }

    /// Settings (#530): exact RGB through Denon's color message, or the 64-color table; repainted at once.
    /// Settings' choice for Shift + Needle Drop's fader (#609). Each touch reads it at touch-down; relative asks for
    /// Syndicate's Volume.
    private var stripFaderSetting = StripFaderSetting()
    public func setStripFader(_ setting: StripFaderSetting) {
        stripFaderSetting = setting
        for bridge in bridges { bridge.stripFaderSetting = setting }
        status.requiredSubscriptions = requiredSubscriptions
    }

    public func setColorMessages(_ on: Bool) {
        colorMessages = on
        for bridge in bridges { bridge.setColorMessages(on) }
        disconnectFailedOutputs()
    }

    /// Settings (#532): the color-message LEDs' brightness in percent; what changes is sent at once.
    public func setLightBrightness(_ percent: Int) {
        lightBrightness = percent
        for bridge in bridges { bridge.setLightBrightness(percent) }
        disconnectFailedOutputs()
    }

    /// Settings (#151): vivid or exact ring colors, repainted at once.
    public func setRingColors(_ mode: RingColors) {
        ringColors = mode
        for bridge in bridges { bridge.setRingColors(mode) }
        disconnectFailedOutputs()
    }

    /// Settings (#19): the LEDs switch, for every controller.
    public func setLEDs(enabled: Bool) {
        ledsEnabled = enabled
        for bridge in bridges { bridge.setLEDsEnabled(enabled) }
        disconnectFailedOutputs()
    }

    /// The one place a Resend is sent. One already waiting for its answer isn't sent again.
    private func requestResend() {
        checkHealth { FeedbackHealth.Output(resend: $0.requestResend(at: $1)) }
    }

    private func sendResend() {
        controllers[0].bridge.send("Feedback/Resend", .int(1))
    }

    // MARK: LED sweep (#26)

    /// Starts the LED sweep on the first controller, `delay` seconds per color (0.6, as the Python led-sweep).
    public func startLEDSweep(delay: Double = 0.6) {
        let bridge = controllers[0].bridge
        guard bridge.output != nil else {
            diagnostics?(.sweep("No controller output is open, so there is nothing to sweep."))
            return
        }
        bridge.ledsHeld = true
        sweep = (clock.now, LEDSweep.steps(for: bridge.mapping, delay: delay), 0)
        status.sweeping = true
        runSweep()
    }

    /// Whether an LED sweep is running.
    public var isSweeping: Bool { sweep != nil }

    /// Stops the sweep part-way. Its remaining steps are dropped, and the LEDs repaint.
    public func stopLEDSweep() {
        guard sweep != nil else { return }
        sweep = nil
        diagnostics?(.sweep("LED sweep stopped."))
        endSweep()
    }

    /// Gives the LEDs back to the bridge, painted from its current state.
    private func endSweep() {
        status.sweeping = false
        let bridge = controllers[0].bridge
        bridge.ledsHeld = false
        bridge.repaintLEDs()
    }

    /// Sends every sweep step that is due.
    private func runSweep() {
        guard var current = sweep else { return }
        let bridge = controllers[0].bridge
        while current.next < current.steps.count, clock.now - current.start >= current.steps[current.next].at {
            let step = current.steps[current.next]
            for send in step.sends { bridge.sweepLED(send.note, send.velocity) }
            for caption in step.captions { diagnostics?(.sweep(caption)) }
            current.next += 1
        }
        if current.next < current.steps.count {
            sweep = current
        } else {
            sweep = nil
            endSweep()
        }
    }

    /// One OSC message in the trace, through the sampler: "/Syndicate/Deck/1/Playing 1".
    private func traceOSC(_ category: TraceCategory, _ message: OSCMessage, _ trace: TraceSink) {
        guard let note = traceSampler.admit(message.address, at: clock.now) else { return }
        let arguments = message.arguments.map(\.pythonText).joined(separator: " ")
        trace(category, message.address + (arguments.isEmpty ? "" : " " + arguments) + note)
    }
}

/// Rapid deck layer steps (#428): the LED repaint and display switch wait this long after the last step. Since a
/// step sends only the lights that differ (#554), it only has to catch true bursts.
enum LayerSettle {
    static let interval = 0.3
}
