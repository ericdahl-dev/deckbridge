import AppKit
import ControllerBridgeCore
import ControllerBridgePresentation
import Observation

/// What the menu shows. A main-actor copy: the adapters report into it, and nothing reads the Coordinator from here.
@MainActor @Observable
final class BridgeStatus {
    enum Feedback: Equatable {
        case starting
        case listening(port: Int)
        case portInUse(port: Int)
        case failed(String)
    }

    var controllers: [String] = []
    /// The Syndicate deck this controller drives.
    var deck = 1
    /// Each controller's deck, connection and last disconnect or reconnect, from the Coordinator (#20).
    var bridges: [ControllerStatus] = []
    /// Every MIDI source and the controller profile it matched (#43); one with no profile is listed, not bridged.
    var devices: [DeviceStatus] = []
    /// Whether Syndicate's feedback is arriving (#21): the listener can be up while Syndicate is quiet or gone.
    var syndicateFeedback: FeedbackState = .waiting
    /// Syndicate answers with no deck info: its OSC FEEDBACK subscriptions are off (#150).
    var noDeckData = false
    /// LED subscriptions a loaded deck's answer lacked (#150).
    var missingSubscriptions: [Subscription] = []
    /// Another DJ app holds the LC6000 as its host (#333).
    var otherHost = false
    /// The jog display firmware found on the unit (#456), for Settings' Firmware row.
    var displayFound: DisplayFound?
    /// What the controllers' profiles need, for the setup guide (#211).
    // The eight every profile needs until the Coordinator says (BarRamp joins only with the jog display on, #165).
    var requiredSubscriptions: [Subscription] = Subscription.always
    /// The last time Syndicate's feedback stopped, for the menu.
    var lastDropout: String?
    /// When feedback last dropped, as the time to show ("21:14"), stamped as it happens (#66).
    var lastDropoutTime: String?
    /// The Syndicate OSC port in use, from settings (#66), for the panel's ports line.
    var oscPort = 9090
    /// Which part couldn't start, when `problem` is set (#88).
    var stopReason: BridgeState.StopReason = .midi
    /// Why the last deck change was refused, if it was (#90).
    var deckProblem: String?
    /// An LED sweep is running (#26).
    var sweeping = false
    /// The deck colors in use, for the badges (#123).
    var deckColors = DeckColors.defaults
    /// The built-in demo controller is running (#64). Off at launch and never saved.
    var demo = false
    var feedback: Feedback = .starting
    var problem: String?
    /// The running mapping (#24): the bundled profile's name, or that an imported file is in use.
    var mappingInUse = "Bundled default"

    var isConnected: Bool {
        guard problem == nil, !controllers.isEmpty, case .listening = feedback else { return false }
        return true
    }
}

/// Starts the bridge at launch and keeps its adapters alive.
@MainActor
final class BridgeModel {
    let status = BridgeStatus()
    /// What the Diagnostics window shows (#26).
    let diagnostics = DiagnosticsLog()
    /// What Diagnostics › Jog display shows (#221).
    let jogSimulator = JogSimulatorLog()
    private var listener: FeedbackListener?
    private var ticker: Ticker?
    private var midi: CoreMIDISystem?
    private var producer: EventPipe.Producer?
    private var engine: Task<Void, Never>?
    private var sleepObservers: [any NSObjectProtocol] = []
    private var osc: OSCDestination?
    /// The display feed's destination (#616): the panel's host and port, by address or by name.
    private var displayFeedDestination: OSCDestination?
    /// The deck panel's USB cable (#667) and the queue its frames go out on.
    private var panelCable: PanelCable?
    private var cableFeedQueue: DisplayFeedQueue?
    private let storage = UserDefaultsStorage()
    /// What Settings shows and changes (#19). Saved in user defaults.
    /// The running profile's deck layers (#79): empty for a controller without them.
    private(set) var layers: [Mapping.Layer] = []
    private(set) var settings: BridgeSettings?
    /// Puts settings into effect (#136): everything but the host at once, the host when it opens.
    private var applier: SettingsApplier?
    /// The profiles that ship with the app, and the ones running with any import applied (#24). The decisions are
    /// in ControllerBridgeCore's MappingLibrary (#94); this keeps the file.
    private var library: MappingLibrary?
    var profiles: [ControllerProfile] { library?.profiles ?? [] }
    /// What Settings says after the last good import: that Settings owns Deck, Channel and OSC (#93).
    var lastImportNote: String? { library?.importNote }

    init() {
        // Line-buffered stdout, so the smoke script sees the log even when it stops the app.
        setvbuf(stdout, nil, _IOLBF, 0)
        start()
        AppDelegate.model = self
    }

    #if DEBUG
    /// Snapshots only (#68): settings to show, with no bridge, MIDI or network started. Nil shows the stopped state.
    init(preview settings: BridgeSettings?) {
        self.settings = settings
    }
    #endif

    /// Quit: release everything held in Syndicate, then call `done`. Calls it after one second at the latest, so a
    /// stuck engine can't stop the app from quitting.
    /// The Diagnostics window opened or closed: only while it's open does the engine build anything for it.
    func setDiagnostics(open: Bool) {
        producer?.diagnostics(open: open)
        jogSimulator.feed.setVisible(open)
    }
    func startLEDSweep(delay: Double) { producer?.send(.ledSweep(delay: delay)) }
    func stopLEDSweep() { producer?.send(.stopLEDSweep) }
    /// The meter capture (#582): every Meter value for `seconds`, to a CSV in Logs/DeckBridge (Debug builds).
    func captureMeter(seconds: Double) { producer?.send(.startMeterCapture(seconds: seconds)) }
    /// The deck the jog display preview follows with no controller connected (#221); nil, the first loaded.
    func setJogPreviewDeck(_ deck: Int?) { producer?.send(.setJogPreviewDeck(deck)) }
    /// Turns the demo controller (#64) on or off. In memory only: it is off again at the next launch.
    func setDemo(_ on: Bool) { producer?.demo(on: on) }
    /// The device the capture window should preselect (#200): read when it opens, or at once if it's already open
    /// (#316), so it never lingers for a later open.
    let captureRequest = CaptureRequest()

    /// Pauses (a source) or gives back (nil) a controller while the capture window records it (#186).
    func setCapture(source: MIDIEndpoint.ID?) { producer?.send(.setCapture(source: source)) }

    /// The panel's deck picker (#66): only that controller's deck changes, through the same path as Settings, so a
    /// held control is released on the old deck first.
    func setDeck(_ deck: Int, controller index: Int) {
        guard var new = settings, new.controllers.indices.contains(index), new.controllers[index].deck != deck else { return }
        new.controllers[index].deck = deck
        // At once, never waiting on the network (#136). A refused change says why, under the picker (#90).
        guard let applier else {
            status.deckProblem = "The bridge isn't running, so the deck can't change. Quit and reopen it."
            return
        }
        do {
            try applier.applyNow(new)
            status.deckProblem = nil
        } catch {
            switch error {
            case .invalid(let list): status.deckProblem = list.joined(separator: " ")
            case .fields(let list): status.deckProblem = list.map(\.message).joined(separator: " ")
            }
        }
    }

    /// Ends an open capture (#187: turns off what the LED test lit), run first when the app quits.
    var endCapture: (() -> Void)?

    func quit(_ done: @escaping @MainActor () -> Void) {
        endCapture?()
        endCapture = nil
        guard let producer, let engine else { return done() }
        var finished = false
        let finish = { if !finished { finished = true; done() } }
        producer.stop()
        Task { @MainActor in
            await engine.value
            finish()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            finish()
        }
    }

    /// Opens Syndicate's host in the background (#84, #109): the status shows a failure until it's fixed.
    private func connectOSC(host: String, port: Int) {
        guard let osc else { return }
        let status = status, log = UnifiedLogSink()
        Task { @MainActor in
            if let problem = await osc.connect(host: host, port: port) {
                status.problem = problem
                status.stopReason = .oscSender
                log.log(problem)
            } else if status.stopReason == .oscSender, osc.isReady, osc.lastError == nil {
                // Nil can also mean a newer connect overtook this one (#135): clear only once a destination is open.
                status.problem = nil
            }
        }
    }

    /// What the display feed is doing (#618), for Settings' status line: from the applied setting and the feed's own
    /// destination. Read again each second while it shows; "Sending" never means the panel is receiving.
    var displayFeedStatus: DisplayFeedStatus {
        guard let settings, let displayFeedDestination else { return .off }
        return DisplayFeedStatus(settings.displayFeed, displayFeedDestination)
    }

    /// The USB cable's status line (#667): its switch, and the panel's port as last found.
    var cableFeedStatus: CableFeedStatus {
        CableFeedStatus(cable: settings?.displayFeed.cable ?? false, port: panelCable?.state ?? .noPanel)
    }

    /// The cable's switch (#667): the port opens while it's on, and lets go after the goodbye when it goes off.
    private func setCable(_ on: Bool) {
        guard let panelCable, let cableFeedQueue else { return }
        panelCable.setEnabled(on) { cableFeedQueue.flush(timeout: 0.5) }
    }

    /// Opens the display feed's host in the background (#616). A failure is logged; Settings shows it from #618.
    private func connectDisplayFeed(_ feed: DisplayFeedSettings) {
        guard let displayFeedDestination else { return }
        let log = UnifiedLogSink()
        Task { @MainActor in
            if let problem = await displayFeedDestination.connect(host: feed.host.trimmingCharacters(in: .whitespaces), port: feed.port) {
                log.log("Display feed: \(problem)")
            }
        }
    }

    /// Release held controls before the Mac sleeps, and re-check the devices when it wakes.
    private func observeSleep(_ producer: EventPipe.Producer) {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in producer.sleep() },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                producer.wake()
                // A `.local` host may have a new address after sleep (#84).
                Task { @MainActor in
                    await self?.osc?.reresolve()
                    await self?.displayFeedDestination?.reresolve()
                }
            },
        ]
    }

    /// The MIDI devices Settings can pick from.
    var sources: [MIDIEndpoint] { midi?.sources ?? [] }
    var destinations: [MIDIEndpoint] { midi?.destinations ?? [] }

    /// Saves `new` and puts it into effect, or throws the problems and changes nothing. Deck and device changes go
    /// through the pipe, so the Coordinator releases held controls first.
    /// Returns a note when the settings were saved but can't take effect until a restart.
    /// Async: a host name is looked up off the main actor first (#84), and Settings stays usable meanwhile.
    @discardableResult
    func apply(_ new: BridgeSettings) async throws(SettingsError) -> String? {
        var new = new
        new.syndicateHost = new.syndicateHost.trimmingCharacters(in: .whitespaces)
        guard settings != nil, producer != nil, let osc, let applier else {
            // Not running, such as a Syndicate host the sender couldn't open (#88): save valid settings anyway, so a
            // fixed host is used at the next launch. Never a silent success (#62): say a restart is needed.
            guard settings != nil else {
                throw .invalid(["The bridge isn't running, so settings can't be applied. Quit and reopen it."])
            }
            try new.save(to: storage)
            settings = new
            return "Saved. Quit and reopen the bridge to use these settings."
        }
        // Everything but the host applies at once; a new host opens after, and a failure goes under its field (#136).
        try await applier.apply(new, senderReady: osc.isReady)
        if osc.isReady, status.stopReason == .oscSender { status.problem = nil }
        return nil
    }

    /// One applied change, from the applier: tell the Coordinator and update the status.
    private func putIntoEffect(old: BridgeSettings, new: BridgeSettings) {
        settings = new
        guard let producer else { return }
        if new.controllers != old.controllers {
            // A controller following its own layers runs as one entry per layer (#79).
            producer.send(.setControllers(ControllerSettings.expanded(new.controllers, layers: layers)))
            status.deck = new.controllers[0].deck
        }
        status.oscPort = new.syndicatePort
        if new.ledsEnabled != old.ledsEnabled { producer.send(.setLEDs(enabled: new.ledsEnabled)) }
        if new.appearance != old.appearance { NSApplication.shared.appearance = new.appearance.nsAppearance }
        if new.followSyndicateDeckColors != old.followSyndicateDeckColors || new.customDeckColors != old.customDeckColors {
            producer.send(.setDeckColors(followSyndicate: new.followSyndicateDeckColors, custom: new.customDeckColors))
        }
        if new.ringColors != old.ringColors { producer.send(.setRingColors(new.ringColors)) }
        if new.colorMessages != old.colorMessages { producer.send(.setColorMessages(new.colorMessages)) }
        if new.lightBrightness != old.lightBrightness { producer.send(.setLightBrightness(new.lightBrightness)) }
        if new.profileChoices != old.profileChoices { producer.send(.setProfileChoices(new.profileChoices)) }
        if new.jogDisplay != old.jogDisplay { producer.send(.setJogDisplay(enabled: new.jogDisplay)) }
        if new.displayFirmware != old.displayFirmware { producer.send(.setDisplayFirmware(new.displayFirmware)) }
        if new.keyDisplay != old.keyDisplay { producer.send(.setKeyDisplay(new.keyDisplay)) }
        if new.stripFader != old.stripFader { producer.send(.setStripFader(new.stripFader)) }
        if new.displayFeed != old.displayFeed {
            // A new host or port opens first; the Coordinator sends the full snapshot again once it's open.
            if new.displayFeed.enabled, new.displayFeed.host != old.displayFeed.host || new.displayFeed.port != old.displayFeed.port || !old.displayFeed.enabled {
                connectDisplayFeed(new.displayFeed)
            }
            producer.send(.setDisplayFeed(new.displayFeed))
            if new.displayFeed.cable != old.displayFeed.cable { setCable(new.displayFeed.cable) }
        }
        if new.feedbackPort != old.feedbackPort || new.feedbackListen != old.feedbackListen { listen(new) }
    }

    /// (Re)binds the feedback listener. The old one is closed first; a failure shows in the status, never crashes.
    private func listen(_ settings: BridgeSettings) {
        guard let producer else { return }
        listener?.stop()
        listener = nil
        let log = UnifiedLogSink()
        let host = settings.feedbackListen.address, port = settings.feedbackPort
        do {
            listener = try FeedbackListener.start(host: host, port: port, producer: producer)
            status.feedback = .listening(port: port)
            log.log("Feedback listening on \(host):\(port)")
        } catch {
            status.feedback = error.isAddressInUse ? .portInUse(port: port) : .failed(error.description)
            log.log("Feedback listener on \(host):\(port) failed: \(error)")
        }
    }

    private func start() {
        let log = UnifiedLogSink()
        // Each connected device gets the profile its name matches (#43). The OSC settings come from the first
        // profile's mapping until Settings (#19) holds them.
        let bundled: [ControllerProfile]
        do { bundled = try ControllerProfile.bundled() } catch {
            status.problem = "Couldn't load the controller profiles: \(error)"
            status.stopReason = .profiles
            return
        }
        // A saved import (#24) applies at launch; one that no longer passes the check is set aside, and says why.
        let library = MappingLibrary(bundled: bundled, saved: MappingStore.saved)
        self.library = library
        let profiles = library.profiles
        status.mappingInUse = library.inUse
        if !library.launchProblems.isEmpty {
            log.log("The saved mapping import was ignored: " + library.launchProblems.joined(separator: "; "))
        }
        let mapping = profiles[0].mapping
        layers = mapping.midi.layers
        let settings = BridgeSettings.load(from: storage, defaults: .defaults(from: mapping))
        self.settings = settings
        NSApplication.shared.appearance = settings.appearance.nsAppearance
        status.deck = settings.controllers[0].deck
        status.oscPort = settings.syndicatePort
        let pipe = EventPipe()
        let status = status
        let diagnostics = diagnostics
        let jogSimulator = jogSimulator

        do {
            midi = try CoreMIDISystem(producer: pipe.producer) { names in
                Task { @MainActor in status.controllers = names.sorted() }
            }
        } catch {
            status.problem = "Couldn't start CoreMIDI: \(error)"
            status.stopReason = .midi
            log.log(status.problem!)
            return
        }

        // Syndicate's host, by address or by name (#84). Launch never waits on it: the bridge starts now, and sends
        // begin once the host opens. Until then, or if it can't (#109), the status says so and Apply fixes it.
        let osc = OSCDestination(
            resolver: SystemHostResolver(), open: { ip, port in try UDPSink(ipv4: ip, port: port) }, clock: SystemClock()
        )
        let resyncProducer = pipe.producer
        osc.onReady = { resyncProducer.send(.resync) }
        osc.onSendFailure = { [weak osc] in Task { await osc?.reresolve() } }
        self.osc = osc
        connectOSC(host: settings.syndicateHost, port: settings.syndicatePort)
        // The display feed (#616): its own destination, behind a queue so the engine never waits on it, and dropping
        // when it's behind. Opened only while the feed is on; the full snapshot goes again each time it opens.
        let feedDestination = OSCDestination(
            resolver: SystemHostResolver(), open: { ip, port in try UDPSink(ipv4: ip, port: port) }, clock: SystemClock()
        )
        let feedProducer = pipe.producer
        feedDestination.onReady = { feedProducer.send(.displayFeedReady) }
        feedDestination.onSendFailure = { [weak feedDestination] in
            #if DEBUG
            // Failing sends to the display (#636), at most once a second as the destination reports them.
            DebugTrace.shared.sink(.displayFeed, "sends failing: \(feedDestination?.lastError ?? "unknown"), looking the host up again")
            #endif
            Task { await feedDestination?.reresolve() }
        }
        displayFeedDestination = feedDestination
        let displayFeed = DisplayFeedQueue(feedDestination)
        #if DEBUG
        displayFeed.trace = DebugTrace.shared.sink
        #endif
        if settings.displayFeed.enabled { connectDisplayFeed(settings.displayFeed) }
        // The USB cable (#667): its own port and queue, so a slow cable never makes Wi-Fi's feed drop.
        let cable = PanelCable()
        cable.onOpen = { feedProducer.send(.cableFeedReady) }
        let cableFeed = DisplayFeedQueue(CableFeedSender(cable))
        #if DEBUG
        cableFeed.trace = DebugTrace.shared.sink
        #endif
        panelCable = cable
        cableFeedQueue = cableFeed
        producer = pipe.producer
        applier = SettingsApplier(
            settings: settings, storage: storage, connect: { [osc] host, port in await osc.connect(host: host, port: port) }
        ) { [weak self] old, new in self?.putIntoEffect(old: old, new: new) }
        listen(settings)

        ticker = Ticker(producer: pipe.producer)
        observeSleep(pipe.producer)
        // Every MIDI send leaves the engine's task through one queue (#552): a port that stops taking data (#428) no
        // longer stalls OSC, the ticks or the trace. A port stuck past the bound is said once, and dropped until it
        // reconnects.
        let recoveryProducer = pipe.producer
        let sendQueue = MIDISendQueue(label: "dev.ericdahl.ControllerBridge.midi-send", onStuck: { name in
            log.log("MIDI port \(name) stopped taking data: sends to it are dropped until it takes data again")
        }, onRecovered: { name in
            // What was dropped meanwhile is lost: every light is painted again, or the jog display starts over (#595).
            log.log("MIDI port \(name) takes data again")
            recoveryProducer.send(.afterRecovery(of: name))
        })
        let midi = midi!
        // The engine's loop reads endpoints from snapshots, refreshed on CoreMIDI's setup queue before the Coordinator
        // hears of a change (#595): a hung unit can hold the MIDI server for seconds, and the loop no longer waits.
        let snapshot = SnapshotMIDISystem(inner: midi)
        let queuedMIDI = QueuedMIDISystem(inner: snapshot, queue: sendQueue)
        let coreJogDisplay = try? CoreMIDIJogDisplay(client: midi.client, producer: pipe.producer)
        let snapshotJog = coreJogDisplay.map { SnapshotJogDisplayPort(inner: $0) }
        // Its ports are remembered until a device comes or goes (#552), then asked again.
        midi.observeChanges {
            coreJogDisplay?.forgetEndpoints()
            snapshotJog?.refresh()
            snapshot.refresh()
        }
        let jogDisplay = snapshotJog.map { sendQueue.jogDisplayPort($0) }
        // The entries the Coordinator starts with: the saved ones, a controller following its layers as one per layer
        // (#79). It starts straight on them (#105), so nothing is sent after start to correct it.
        let running = ControllerSettings.expanded(settings.controllers, layers: layers)
        engine = Task.detached(name: "Bridge engine") {
            await BridgeHost.run(
                profiles: profiles, midi: queuedMIDI, osc: osc, log: log, status: status, diagnostics: diagnostics,
                jogSimulator: jogSimulator, controllers: running, ledsEnabled: settings.ledsEnabled, jogDisplay: jogDisplay,
                displayFeed: displayFeed, cableFeed: cableFeed, events: pipe.events
            )
        }
        // The saved deck colors (#123), queued behind the Coordinator's start.
        pipe.producer.send(.setDeckColors(followSyndicate: settings.followSyndicateDeckColors, custom: settings.customDeckColors))
        pipe.producer.send(.setRingColors(settings.ringColors))
        pipe.producer.send(.setColorMessages(settings.colorMessages))
        // Shift + Needle Drop's fader (#609): the DJ's choice, else the profile's.
        pipe.producer.send(.setStripFader(settings.stripFader))
        pipe.producer.send(.setLightBrightness(LightBrightness.snapped(settings.lightBrightness)))
        // Profiles chosen by hand (#200): a device only they name connects now.
        pipe.producer.send(.setProfileChoices(settings.profileChoices))
        // Before the switch, so the first uploads already know how many slots the unit shows (#425).
        pipe.producer.send(.setDisplayFirmware(settings.displayFirmware))
        // How the key is written (#590), before the first content is shown.
        pipe.producer.send(.setKeyDisplay(settings.keyDisplay))
        // The jog display's beat lead (#720): a hidden default while it's tuned on video, no Settings control.
        // `defaults write dev.ericdahl.ControllerBridge jogDisplayBeatLeadMs -float 70` sets it; unset, the Kit's 60 ms.
        if let ms = UserDefaults.standard.object(forKey: "jogDisplayBeatLeadMs") as? Double {
            pipe.producer.send(.setJogBeatLead(ms / 1000))
        }
        pipe.producer.send(.setJogDisplay(enabled: settings.jogDisplay))
        pipe.producer.send(.setDisplayFeed(settings.displayFeed))
        // After the setting, so the port's opening finds the cable's feed on.
        setCable(settings.displayFeed.cable)

    }

    // MARK: Mapping import, export and reset (#24)

    /// Checks the file and, if it passes, saves a copy and runs it: held controls are released and the controller
    /// resyncs. Returns every problem; on any problem nothing changes and the old mapping keeps running.
    func importMapping(from url: URL) -> [String] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return ["Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"] }
        guard var next = library else { return ["The bridge didn't start, so there is no mapping to change."] }
        let problems = next.importFile(data, named: url.lastPathComponent)
        guard problems.isEmpty else { return problems }
        // Saved before it runs, so what runs is what comes back at the next launch.
        do { try MappingStore.save(data) } catch { return ["Couldn't save the mapping: \(error.localizedDescription)"] }
        library = next
        status.mappingInUse = next.inUse
        producer?.send(.setProfiles(next.profiles))
        return []
    }

    /// Writes the running profile, whole, so it can be edited and imported again.
    func exportMapping(to url: URL) throws {
        guard let active = profiles.first else { return }
        try active.exported().write(to: url, options: .atomic)
    }

    /// Back to the bundled profiles; the saved import is deleted. Returns a problem if it couldn't be, and then
    /// nothing changes, so the import doesn't quietly come back at the next launch.
    func resetMapping() -> String? {
        guard var next = library else { return nil }
        do { try MappingStore.remove() } catch { return "Couldn't remove the imported mapping: \(error.localizedDescription)" }
        next.reset()
        library = next
        status.mappingInUse = next.inUse
        producer?.send(.setProfiles(next.profiles))
        return nil
    }
}

/// Holds quitting until the release sends have gone out (#20), for the menu's Quit button and for Command-Q alike: both
/// go through `NSApplication.terminate`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: BridgeModel?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        model.quit {
            #if DEBUG
            DebugTrace.shared.flush()  // the trace's last line is trustworthy (#653)
            #endif
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// A device for the capture window to preselect (#200, #316), observed so an open window sees it too.
@MainActor @Observable
final class CaptureRequest {
    var device: String?
}
