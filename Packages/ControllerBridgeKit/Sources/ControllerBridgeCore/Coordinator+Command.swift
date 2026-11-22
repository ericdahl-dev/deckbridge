/// Every change the app asks of the Coordinator, as one value (#386): BridgeModel sends it through the event pipe, the
/// Engine routes it by `routing` without naming it, and `apply` runs it. A new command is a case here and a call in
/// BridgeModel; nothing in the pipe or the Engine changes.
extension Coordinator {
    public enum Command: Equatable, Sendable {
        case setDeck(Int, controller: Int)
        case setDevices(input: MIDIEndpoint?, output: MIDIEndpoint?, controller: Int)
        case setLEDs(enabled: Bool)
        /// Start (a source) or end (nil) the capture window's pause of a controller (#186).
        case setCapture(source: MIDIEndpoint.ID?)
        case setDeckColors(followSyndicate: Bool, custom: DeckColors)
        case setRingColors(RingColors)
        /// Pads and ring through Denon's color message, or the 64-color table (#530).
        case setColorMessages(Bool)
        /// Shift + Needle Drop's fader (#609).
        case setStripFader(StripFaderSetting)
        /// The color-message LEDs' brightness, in percent (#532).
        case setLightBrightness(Int)
        /// The OSC destination opened late (#84): ask Syndicate to resend its state, since what was sent before was dropped.
        case resync
        case setControllers([ControllerSettings])
        /// An imported mapping (#24): the controller profiles to run from now on.
        case setProfiles([ControllerProfile])
        /// Profiles chosen by hand per device name (#200).
        case setProfileChoices([String: String])
        /// Settings' jog display switch (#165).
        case setJogDisplay(enabled: Bool)
        /// Settings' display firmware (#425): Denon's or custom.
        case setDisplayFirmware(DisplayFirmware)
        /// Settings' Key display (#590): the key as Syndicate sends it, or as Camelot codes.
        case setKeyDisplay(KeyNotation)
        /// How early the jog display's beat goes, in seconds (#720): a hidden default (jogDisplayBeatLeadMs), no
        /// Settings control until it's tuned.
        case setJogBeatLead(Double)
        /// The deck the jog display preview follows with no controller connected (#221); nil, the first loaded.
        case setJogPreviewDeck(Int?)
        /// Settings' display feed (#616): on/off, host and port.
        case setDisplayFeed(DisplayFeedSettings)
        /// The display feed's destination opened (#616): what was sent before it was dropped, so the full snapshot
        /// goes again.
        case displayFeedReady
        /// The panel's serial port opened (#667): the cable's snapshot, from whichever Coordinator holds the feed.
        case cableFeedReady
        /// Start the LED sweep, `delay` seconds per color; or stop it part-way (#26).
        case ledSweep(delay: Double)
        case stopLEDSweep
        /// A debug capture of the full-rate meter stream for `seconds` (#582), handed to `meterCaptureSink`.
        case startMeterCapture(seconds: Double)
        /// A MIDI port that had stopped taking data takes it again (#552): the LED writes dropped meanwhile are lost,
        /// so every light is painted again.
        case portRecovered
        /// One of the jog display's ports takes data again (#595): what was dropped meanwhile (needle steps, an
        /// upload's chunks) is worthless, so the display starts over: goodbye, hello, and the full state.
        case jogDisplayRecovered

        /// The command for a port the send queue names as taking data again.
        public static func afterRecovery(of name: String) -> Command {
            MIDISendQueue.jogDisplayPortNames.contains(name) ? .jogDisplayRecovered : .portRecovered
        }

        /// Where a command goes while the demo (#64) has its own Coordinator.
        public enum Routing: Equatable, Sendable {
            /// A settings change: the real Coordinator gets it now, or when the demo ends, in order.
            case waitsForDemo
            /// Always the real Coordinator, demo or not.
            case real
            /// Whichever Coordinator is running: the demo's while it's on.
            case active
            /// The real Coordinator and the demo's both.
            case realAndDemo
        }

        public var routing: Routing {
            switch self {
            // A real device is captured, so the real Coordinator pauses it, demo or not.
            // The meter capture (#582) records what Syndicate sends the real controller.
            case .setCapture, .portRecovered, .jogDisplayRecovered, .startMeterCapture: .real
            // The display feed goes with whichever Coordinator runs (#625), so its destination opening does too.
            case .ledSweep, .stopLEDSweep, .displayFeedReady, .cableFeedReady: .active
            // The preview's deck (#221) holds for the real controller and the demo alike.
            case .setJogPreviewDeck: .realAndDemo
            case .setDeck, .setDevices, .setLEDs, .setDeckColors, .setRingColors, .setColorMessages, .setStripFader, .setLightBrightness, .resync, .setControllers, .setProfiles,
                 .setProfileChoices, .setJogDisplay, .setDisplayFirmware, .setKeyDisplay, .setDisplayFeed, .setJogBeatLead:
                .waitsForDemo
            }
        }
    }

    /// Runs one command: the only place a Command becomes a call.
    public func apply(_ command: Command) {
        switch command {
        case .setDeck(let deck, let controller): setDeck(deck, controller: controller)
        case .setDevices(let input, let output, let controller): setDevices(input: input, output: output, controller: controller)
        case .setLEDs(let enabled): setLEDs(enabled: enabled)
        case .setCapture(let source): setCapture(source: source)
        case .setDeckColors(let follow, let custom): setDeckColors(followSyndicate: follow, custom: custom)
        case .setRingColors(let mode): setRingColors(mode)
        case .setColorMessages(let on): setColorMessages(on)
        case .setStripFader(let setting): setStripFader(setting)
        case .setLightBrightness(let percent): setLightBrightness(percent)
        case .resync: resync()
        case .setControllers(let entries): setControllers(entries)
        case .setProfiles(let profiles): setProfiles(profiles)
        case .setProfileChoices(let choices): setProfileChoices(choices)
        case .setJogDisplay(let enabled): setJogDisplay(enabled: enabled)
        case .setDisplayFirmware(let firmware): setDisplayFirmware(firmware)
        case .setKeyDisplay(let notation): setKeyDisplay(notation)
        case .setJogPreviewDeck(let deck): setJogPreviewDeck(deck)
        case .setJogBeatLead(let seconds): setJogBeatLead(seconds)
        case .setDisplayFeed(let settings): setDisplayFeed(settings)
        case .displayFeedReady: displayFeedReady()
        case .cableFeedReady: cableFeedReady()
        case .ledSweep(let delay): startLEDSweep(delay: delay)
        case .stopLEDSweep: stopLEDSweep()
        case .startMeterCapture(let seconds): startMeterCapture(seconds: seconds)
        case .portRecovered: repaintAfterRecovery()
        case .jogDisplayRecovered: jogDisplayRecovered()
        }
    }
}
