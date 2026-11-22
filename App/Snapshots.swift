#if DEBUG
// Renders the panel in a few states to PNGs, for PR screenshots: `ControllerBridge --render-snapshots <name>`.
// The app is sandboxed, so the PNGs go to <container tmp>/<name>; the path is printed. Compiled out of Release.
import AppKit
import ControllerBridgeCapture
import ControllerBridgeCore
import ControllerBridgeRender
import ControllerBridgePresentation
import SwiftUI

@MainActor
enum Snapshots {
    /// SNAPSHOT_APPEARANCE=light renders the light theme (#127); dark by default.
    static let scheme: ColorScheme = ProcessInfo.processInfo.environment["SNAPSHOT_APPEARANCE"] == "light" ? .light : .dark

    static let fonts = ["Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold", "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold"]
    static var missingFonts: Bool { fonts.contains { NSFont(name: $0, size: 12) == nil } }

    static func render(to name: String) {
        // Theme colors resolve against the app's appearance, so set it to match.
        NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        for font in fonts {
            print("\(font): \(NSFont(name: font, size: 12) == nil ? "MISSING" : "ok")")
        }
        // A missing font would render in the system font and look almost right: stop instead (#171).
        if missingFonts { print("A bundled font is missing; no snapshots."); exit(1) }
        let states: [(String, (BridgeStatus) -> Void)] = [
            ("layers", {
                // The LC6000 following its own layers (#79), switched to layer 2.
                $0.bridges = (1...4).map {
                    ControllerStatus(deck: $0, connected: true, profile: "Denon LC6000 PRIME", activeLayer: $0 == 2, followsLayers: true)
                }
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
            }),
            ("connected", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME")]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
            }),
            // Syndicate's OSC FEEDBACK subscriptions off (#150): NO DECK DATA, and help naming them.
            ("feedback-no-deck-data", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME")]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
                $0.noDeckData = true
            }),
            // A loaded deck answered without Cues (#150): LIVE, and help about the pad colors.
            ("feedback-cues-missing", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME")]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
                $0.missingSubscriptions = [.cues]
            }),
            // The user's own Syndicate had TempoSlider off (#211): named, with what it breaks.
            ("feedback-tempo-slider-missing", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME")]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
                $0.missingSubscriptions = [.tempoSlider, .cues]
            }),
            // Syndicate stopped answering (#21): DROPPED, and the last dropout under the lights.
            ("feedback-dropped", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME")]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .stale
                $0.lastDropout = "Syndicate feedback stopped"
                $0.lastDropoutTime = "21:14"
            }),
            ("connected-master-others", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME", master: true)]
                $0.devices = [
                    DeviceStatus(name: "Denon LC6000 PRIME", profile: "Denon LC6000 PRIME", note: nil),
                    DeviceStatus(name: "IAC Bus 1", profile: nil, note: nil),
                    DeviceStatus(name: "loopMIDI Port", profile: nil, note: nil),
                ]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
            }),
            // Never connected since launch: gray NOT CONNECTED (#66).
            ("not-connected", {
                $0.bridges = [ControllerStatus(deck: 2, connected: false)]
                $0.devices = [
                    DeviceStatus(name: "DDJ-FLX4", profile: nil, note: "No controller profile matches DDJ-FLX4, so it isn't bridged."),
                    DeviceStatus(name: "IAC Bus 1", profile: nil, note: nil),
                ]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
            }),
            // The LC6000 and its WD port (#200): the WD is listed as part of it, never offered for capture.
            ("connected-wd", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME", device: "LC6000 PRIME")]
                $0.devices = [
                    DeviceStatus(name: "LC6000 PRIME", profile: "Denon LC6000 PRIME", note: nil),
                    DeviceStatus(name: "LC6000 PRIME WD", profile: nil, note: nil, partOf: "Denon LC6000 PRIME"),
                ]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
            }),
            // Another DJ app holds the LC6000 as its host (#333).
            ("other-host", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME")]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
                $0.otherHost = true
            }),
            ("port-in-use", {
                $0.bridges = [ControllerStatus(deck: 3, connected: true, profile: "Denon LC6000 PRIME")]
                $0.feedback = .portInUse(port: 9096)
            }),
            // The built-in demo controller (#64): DEMO leads, so it is never mistaken for hardware.
            ("demo", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME")]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
                $0.demo = true
            }),
            // Connected earlier, then pulled mid-set: orange UNPLUGGED (#66).
            ("unplugged", {
                $0.bridges = [ControllerStatus(
                    deck: 1, connected: false, lastEvent: "Disconnected DENON LC6000 PRIME",
                    lastProfile: "Denon LC6000 PRIME", lastDisconnect: .unplugged
                )]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
            }),
            // A failed send or read (#91): MIDI ERROR, with what to check first.
            ("midi-error", {
                $0.bridges = [ControllerStatus(
                    deck: 1, connected: false, lastEvent: "Disconnected DENON LC6000 PRIME (MIDI send failed)",
                    lastProfile: "Denon LC6000 PRIME", lastDisconnect: .sendFailed
                )]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
            }),
            // Two controllers (#25): a block and a deck picker each; the status line lists both decks.
            ("two-controllers", {
                $0.bridges = [
                    ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME"),
                    ControllerStatus(deck: 3, connected: true, profile: "Denon LC6000 PRIME"),
                ]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
            }),
            // The longest status lines (#66, #171): the budget must still fit them in natural case.
            ("four-controllers", {
                $0.bridges = (1...4).map { ControllerStatus(deck: $0, connected: true, profile: "Denon LC6000 PRIME") }
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
            }),
            ("demo-master", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME", master: true)]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
                $0.demo = true
            }),
            ("starting-deck4", { $0.deck = 4 }),
            ("many-lights", {
                $0.bridges = [ControllerStatus(deck: 2, connected: true, profile: "Denon LC6000 PRIME", master: true)]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .live
                $0.problem = "Couldn't open the OSC sender: connect: Network is unreachable"
                $0.stopReason = .oscSender
            }),
            ("waiting", {
                $0.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME")]
                $0.feedback = .listening(port: 9096)
                $0.syndicateFeedback = .waiting
            }),
            ("stopped", { $0.problem = "Couldn't start CoreMIDI: status(\"MIDIClientCreateWithBlock\", -10844)" }),
        ]
        do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) } catch {
            print("Couldn't create \(directory): \(error)"); return
        }
        write(buttonStates, to: "\(directory)/buttons.png")
        write(siteStyles, to: "\(directory)/site-styles.png")
        // The jog display's image (#165), design B, upright, 198×198, for review before any hardware send. The deck
        // colors are the designer's sample ones; the app uses Syndicate's.
        let daybreak = JogDisplayContent(deck: 1, color: [255, 49, 93], title: "Daybreak", artist: "Bill Hamel, Jeremus", key: "A#m",
                                         bpm: 128, playerType: "track")
        let ten = JogDisplayContent(deck: 4, color: [148, 92, 255], title: "Ten (Original Club Mix)",
                                    artist: "Mark Knight, Underworld, Sander Van Doorn", key: "A#m", bpm: 128, playerType: "track")
        let clip = JogDisplayContent(deck: 2, color: [255, 194, 71], playerType: "osc")
        let emptyDeck = JogDisplayContent(deck: 3, color: [32, 224, 196])
        let cases: [(String, JogDisplayContent, Int?, Double?)] = [
            ("deck1-track", daybreak, nil, nil), ("deck4-long-title", ten, nil, nil), ("deck2-osc-clip", clip, nil, nil),
            ("deck3-empty", emptyDeck, nil, nil),
            // As the simulator would show the unit: beat 2 lit and the needle at 126°.
            ("deck4-beat2-marker-simulated", ten, 2, 126.0 / 360),
        ]
        for (name, content, beat, needle) in cases {
            let rgba = JogDisplayRenderer.render(content, litBeat: beat, needle: needle)
            let png = JogImage.png(rgba: rgba, width: JogImage.size, height: JogImage.size)
            do { try Data(png).write(to: URL(fileURLWithPath: "\(directory)/jog-display-\(name).png")) } catch { print("Couldn't write: \(error)") }
        }
        write(siteStyles.environment(\.forcesIncreasedContrast, true), to: "\(directory)/site-styles-increased-contrast.png")
        for (name, configure) in states {
            let status = BridgeStatus()
            configure(status)
            write(StatusPanel(status: status), to: "\(directory)/panel-\(name).png")
            if name == "connected" {
                // Quit pressed while feedback is live: the question in the panel (#131).
                var asking = QuitFlow()
                _ = asking.pressQuit(asks: true)
                write(StatusPanel(status: status, quitFlow: asking), to: "\(directory)/panel-quit-confirm.png")
            }
            if name == "connected" || name == "waiting" {
                write(SetupGuideView(guide: status.setupGuide, presentation: status.presentation), to: "\(directory)/setup-guide-\(name).png")
            }
            write(icons(status.presentation.icon), to: "\(directory)/icon-\(name).png")
        }
        // Settings (#68), through an NSHostingView: ImageRenderer can't draw its AppKit controls. One PNG per tab (#171):
        // a hosting view can't draw the Settings window's toolbar, so each pane renders on its own with its footer.
        let defaults = BridgeSettings.defaults(from: try! ControllerProfile.bundled()[0].mapping)
        for tab in SettingsTab.allCases {
            let name = tab.title.lowercased()
            writeAppKit(SettingsView(model: BridgeModel(preview: defaults), snapshotTab: tab), to: "\(directory)/settings-\(name).png")
        }
        var two = defaults
        two.controllers.append(ControllerSettings(deck: 3, input: nil, output: nil))
        writeAppKit(SettingsView(model: BridgeModel(preview: two), snapshotTab: .controller),
                    to: "\(directory)/settings-controller-two-controllers.png")
        // Four controllers in a window as tall as a 13-inch screen allows: the pane scrolls and the footer stays pinned
        // (#177). Shown at its end by offsetting the pane: a hosting view outside a window can't scroll.
        var four = defaults
        for deck in 2...4 { four.controllers.append(ControllerSettings(deck: deck, input: nil, output: nil)) }
        writeAppKit(SettingsView(model: BridgeModel(preview: four), snapshotTab: .controller, room: 760, scrolledToEnd: true),
                    to: "\(directory)/settings-controller-four-controllers-end.png")
        // A refused Apply: the field errors on the Syndicate tab, and the footer naming each problem's tab.
        var bad = defaults
        bad.syndicateHost = ""
        writeAppKit(SettingsView(model: BridgeModel(preview: bad), snapshotTab: .syndicate, problems: bad.fieldProblems),
                    to: "\(directory)/settings-syndicate-refused.png")
        // The Controller picker (#200) for an unsupported device, and with nothing connected.
        let unsupported = BridgeModel(preview: defaults)
        unsupported.status.bridges = [ControllerStatus(deck: 1, connected: false)]
        unsupported.status.devices = [DeviceStatus(name: "DDJ-FLX4", profile: nil, note: nil)]
        writeAppKit(SettingsView(model: unsupported, snapshotTab: .controller), to: "\(directory)/settings-controller-unsupported.png")
        let stopped = BridgeModel(preview: nil)
        stopped.status.problem = "Couldn't start CoreMIDI"
        writeAppKit(SettingsView(model: stopped), to: "\(directory)/settings-stopped.png")
        captureSnapshots(directory)
        // The Diagnostics window (#26), with lines as the Kit formats them.
        let log = DiagnosticsLog()
        let monitor: [MIDIEvent] = [
            .noteOn(channel: 0, note: 1, velocity: 127), .noteOff(channel: 0, note: 1, velocity: 0),
            .noteOn(channel: 0, note: 32, velocity: 127), .controlChange(channel: 0, controller: 17, value: 10),
            .controlChange(channel: 0, controller: 99, value: 64),
        ]
        for (index, event) in monitor.enumerated() {
            log.append(.midiIn(event, label: ["play", "play", "pad1", "jog_msb", "UNMAPPED"][index], at: 1234.5 + Double(index) * 0.1))
        }
        for line in ["Color sweep: velocity shown on every pad and the ring. Note what each looks like.",
                     "  velocity  0 (0x00) = rgb222 r0 g0 b0", "  velocity  1 (0x01) = rgb222 r0 g0 b1"] {
            log.append(.sweep(line))
        }
        log.append(.oscOut(OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])))
        log.append(.oscIn(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)])))
        log.append(.oscIn(OSCMessage("/Syndicate/Deck/1/Progress", [.float(0.25)])))
        // A connected controller with its LED output open, and one with no controller at all (#70).
        let connected = BridgeStatus()
        connected.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME", outputOpen: true)]
        connected.feedback = .listening(port: 9096)
        connected.syndicateFeedback = .live
        let empty = DiagnosticsLog()
        for tab in DiagnosticsWindow.Tab.allCases {
            let name = tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            let window = DiagnosticsWindow(
                log: log, status: connected, sweeping: tab == .sweep, setOpen: { _ in }, startSweep: { _ in }, stopSweep: {},
                hiddenNotes: [52], tab: tab, scrolls: false
            )
            // Through AppKit: the filter field and the pickers (#218) are AppKit controls.
            writeAppKit(window.frame(width: 720, height: 460), to: "\(directory)/diagnostics-\(name).png", width: 720)
            let blank = DiagnosticsWindow(
                log: empty, status: BridgeStatus(), sweeping: false, setOpen: { _ in }, startSweep: { _ in }, stopSweep: {},
                tab: tab, scrolls: false
            )
            writeAppKit(blank.frame(width: 720, height: 460), to: "\(directory)/diagnostics-\(name)-empty.png", width: 720)
        }
        // The Jog display tab (#221): deck 1 playing with its upload accepted, deck 2 paused and refused, the master on beat 2.
        let jog = JogSimulatorLog()
        let at = Date(timeIntervalSinceReferenceDate: 784_000_000)
        jog.apply(.connected, at: at)
        jog.apply(.uploadStarted(slot: 2, content: JogDisplayContent(deck: 2, color: [255, 255, 0], title: "Night Drive",
                                                                    artist: "Coastal", key: "Fm", bpm: 124, playerType: "track"),
                                 bytes: 9_406), at: at)
        jog.apply(.failed(refusal: 3), at: at)
        jog.apply(.uploadStarted(slot: 1, content: JogDisplayContent(deck: 1, color: [255, 0, 0], title: "Daybreak",
                                                                    artist: "Untitled", key: "A#m", bpm: 128, playerType: "track"),
                                 bytes: 14_812), at: at)
        jog.apply(.shown(slot: 1), at: at)
        jog.apply(.deckPlaying(deck: 1, playing: true), at: at)
        // Each deck's own needle, the master on beat 2 for every ring (#165): deck 1 a little behind the beat, deck 2 paused.
        jog.apply(.masterBeat(2), at: at)
        jog.apply(.deckNeedle(deck: 1, pitchBend: 3_600), at: at)
        jog.apply(.deckNeedle(deck: 2, pitchBend: 12_000), at: at)
        // Decks 3 and 4 from Syndicate only: previewed, not on the unit (#221).
        jog.apply(.preview(JogDisplayContent(deck: 3, color: [0, 255, 255], title: "Sunrise", artist: "Ward", key: "C", bpm: 122,
                                             playerType: "track")), at: at)
        let jogWindow = DiagnosticsWindow(
            log: log, status: connected, sweeping: false, setOpen: { _ in }, startSweep: { _ in }, stopSweep: {},
            jogSimulator: jog, tab: .jog, scrolls: false
        )
        writeAppKit(jogWindow.frame(width: 720, height: 460), to: "\(directory)/diagnostics-jog-display-live.png", width: 720)
        // The jog display simulator from the demo itself (#29): the demo runs 2.3 s on a test clock, mid-bar, and its
        // preview driver's events feed the pane, as in the app with Demo controller on.
        let demoJog = JogSimulatorLog()
        let demoClock = SnapshotClock()
        let session = DemoSession(profile: try! ControllerProfile.bundled()[0], clock: demoClock, log: SnapshotLog(),
                                  ledOutput: DroppedMIDIOutput())
        let preview = JogDisplayDriver(port: nil, clock: demoClock, log: SnapshotLog()) { JogDisplayRenderer.uploadImage($0) }
        preview.onEvent = { demoJog.apply($0, at: at.addingTimeInterval(demoClock.now)) }
        session.coordinator.attachJogDisplay(preview)
        session.start()
        while demoClock.now < 2.3 {
            demoClock.now += 0.01
            session.tick()
        }
        demoJog.tick(at.addingTimeInterval(demoClock.now + 1))
        session.stop()
        let demoStatus = BridgeStatus()
        demoStatus.bridges = [ControllerStatus(deck: 1, connected: true, profile: "Denon LC6000 PRIME")]
        demoStatus.feedback = .listening(port: 9096)
        demoStatus.syndicateFeedback = .live
        demoStatus.demo = true
        let demoWindow = DiagnosticsWindow(
            log: log, status: demoStatus, sweeping: false, setOpen: { _ in }, startSweep: { _ in }, stopSweep: {},
            jogSimulator: demoJog, tab: .jog, scrolls: false
        )
        writeAppKit(demoWindow.frame(width: 720, height: 460), to: "\(directory)/diagnostics-jog-display-demo.png", width: 720)
        // The OSC log filtered to deck 1, received only, and paused (#218).
        log.deck = 1
        log.direction = .received
        log.togglePause()
        let filtered = DiagnosticsWindow(
            log: log, status: connected, sweeping: false, setOpen: { _ in }, startSweep: { _ in }, stopSweep: {},
            tab: .osc, scrolls: false
        )
        writeAppKit(filtered.frame(width: 720, height: 460), to: "\(directory)/diagnostics-osc-log-filtered.png", width: 720)
        // The user's case (#261): TempoSlider and Cues off, listed above the OSC log as in the panel.
        let missing = BridgeStatus()
        missing.bridges = connected.bridges
        missing.feedback = .listening(port: 9096)
        missing.syndicateFeedback = .live
        missing.missingSubscriptions = [.tempoSlider, .cues]
        let missingWindow = DiagnosticsWindow(
            log: log, status: missing, sweeping: false, setOpen: { _ in }, startSweep: { _ in }, stopSweep: {},
            tab: .osc, scrolls: false
        )
        writeAppKit(missingWindow.frame(width: 720, height: 560), to: "\(directory)/diagnostics-osc-log-missing.png", width: 720)
    }

    /// The shared button styles (#67): normal, selected (bar + heavier text) and keyboard focus (ring).
    private static var buttonStates: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Button("Normal") {}.buttonStyle(FlatButtonStyle())
                Button("Selected") {}.buttonStyle(FlatButtonStyle(selected: true))
                Button("Focused") {}.buttonStyle({ var style = FlatButtonStyle(); style.showsFocusForSnapshot = true; return style }())
            }
            Button("Setup guide…") {}.buttonStyle(LinkButtonStyle())
        }
        .padding(Theme.Space.xl)
        .frame(width: 360)
        .background(Theme.panel)
    }

    /// The site's components (#171): pills normal, focused and disabled, a segmented control, a chip on a card.
    private static var siteStyles: some View {
        VStack(alignment: .leading, spacing: Theme.Step.x4) {
            HStack(spacing: Theme.Step.x2) {
                Button("Done: feedback live") {}.buttonStyle(PillButtonStyle(kind: .primary))
                Button("Settings…") {}.buttonStyle(PillButtonStyle())
                Button("Quit") {}.buttonStyle(PillButtonStyle(kind: .quiet))
            }
            HStack(spacing: Theme.Step.x3) {
                Button("Focused") {}.buttonStyle({ var style = PillButtonStyle(kind: .primary); style.showsFocusForSnapshot = true; return style }())
                Button("Focused") {}.buttonStyle({ var style = PillButtonStyle(); style.showsFocusForSnapshot = true; return style }())
                Button("Apply") {}.buttonStyle(PillButtonStyle(kind: .primary)).disabled(true)
            }
            SegmentedPills(options: ["MIDI Monitor", "LED Sweep", "OSC Log"], title: { $0 }, selection: .constant("MIDI Monitor"))
            VStack(alignment: .leading, spacing: Theme.Step.x2) {
                Text("Controller").font(Theme.labelFont).foregroundStyle(Theme.caption)
                HStack {
                    ToneChip(word: "UNMAPPED", tone: .attention, spoken: "Unmapped")
                    Spacer()
                }
            }
            .padding(Theme.Step.x3)
            .card()
        }
        .padding(Theme.Step.x6)
        .frame(width: 400)
        .background(Theme.panel)
    }

    private static func icons(_ state: IconState) -> some View {
        // The template icon on a light and a dark menu bar.
        HStack(spacing: 0) {
            Image(nsImage: MenuBarIcon.image(state)).renderingMode(.template).foregroundStyle(.black)
                .padding(6).background(Color(white: 0.92))
            Image(nsImage: MenuBarIcon.image(state)).renderingMode(.template).foregroundStyle(.white)
                .padding(6).background(Color(white: 0.15))
        }
    }

    /// Through AppKit, so AppKit-backed controls (a text field, a menu picker) draw, which ImageRenderer can't.
    private static func writeAppKit(_ view: some View, to path: String, width: CGFloat = 440) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // Lay out tall first, so the fitting height is the whole form, then shrink to it.
        host.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: host.fittingSize.height))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("Couldn't render \(path)"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { print("Couldn't render \(path)"); return }
        do { try png.write(to: URL(fileURLWithPath: path)); print("Wrote \(path)") } catch { print("Couldn't write \(path): \(error)") }
    }

    private static func write(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        // 2 by default; SNAPSHOT_SCALE=4 renders big enough for Mac App Store screenshots (#29).
        renderer.scale = Double(ProcessInfo.processInfo.environment["SNAPSHOT_SCALE"] ?? "") ?? 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("Couldn't render \(path)"); return
        }
        do { try png.write(to: URL(fileURLWithPath: path)); print("Wrote \(path)") } catch { print("Couldn't write \(path): \(error)") }
    }

    // MARK: The capture window (#186), its states on the demo controller's traffic

    private static func captureSnapshots(_ directory: String) {
        let lc6000 = MIDIEndpoint(id: 1001, name: "LC6000 PRIME")
        let choices = [
            CaptureController.Choice(name: lc6000.name, endpoint: lc6000),
            CaptureController.Choice(name: "LC6000 PRIME WD", endpoint: MIDIEndpoint(id: 1002, name: "LC6000 PRIME WD")),
            CaptureController.Choice(name: DemoCapture.deviceName, endpoint: nil),
        ]
        let shots: [(String, CaptureController)] = [
            ("ports", CaptureController(flow: CaptureFlow(appVersion: "1.2.0"), now: 0, choices: choices, picked: choices[0])),
            ("idle", CaptureController(flow: captureFlow(at: "idle", fed: false), now: 2.2)),
            ("waiting", CaptureController(flow: captureFlow(at: "deck1.play", fed: false), now: 1e6)),
            ("jog", CaptureController(flow: captureFlow(at: "deck1.jog.touch", fed: true), now: 1e6)),
            ("shift", CaptureController(flow: captureFlow(at: "deck1.play.shift", fed: true), now: 1e6)),
            ("layer-select", CaptureController(flow: captureFlow(at: "layer2.select", fed: true), now: 1e6)),
            ("layer-play", CaptureController(flow: captureFlow(at: "deck2.play", fed: true), now: 1e6)),
            // Unplugged mid-step (#229): the banner, with End capture.
            ("disconnected", {
                var flow = captureFlow(at: "deck1.jog.touch", fed: true)
                flow.disconnected(at: 1e6)
                return CaptureController(flow: flow, now: 1e6)
            }()),
            ("ended-early", {
                var flow = captureFlow(at: "deck1.jog.touch", fed: true)
                flow.endCapture(at: 1e6)
                return CaptureController(flow: flow, now: 1e6)
            }()),
            ("done", CaptureController(flow: captureFlow(at: nil, fed: true), now: 1e6)),
            // The LED test (#187): a lit question, and a pad color question.
            // The LED test with its flag on, as for the supervised check; "done" above shows it off (the default).
            ("done-led-offer", CaptureController(flow: captureFlow(at: nil, fed: true, ledTest: true), now: 1e6)),
            ("led-lit", {
                var flow = captureFlow(at: nil, fed: true, ledTest: true)
                flow.startLEDs(scope: .full, at: 1e6)
                _ = flow.dueSends(at: 1e6)  // Play lit, so the answers are on
                return CaptureController(flow: flow, now: 1e6)
            }()),
            ("led-color", {
                var flow = captureFlow(at: nil, fed: true, ledTest: true)
                flow.startLEDs(scope: .full, at: 1e6)
                // Each answer waits for its probe to go out: let the sends out, 100 ms apart, between answers.
                var now = 1e6
                func shown() { while flow.hasPendingSends { _ = flow.dueSends(at: now); now += 0.1 } }
                shown()
                while flow.ledProbe?.question != .color {
                    flow.answerLED(.lit(true), at: now)
                    shown()
                }
                flow.answerLED(.color("red"), at: now)
                shown()
                return CaptureController(flow: flow, now: 1e6)
            }()),
            ("done-note", {
                var flow = captureFlow(at: nil, fed: true)
                flow.note = "Firmware 1.3"
                return CaptureController(flow: flow, now: 1e6)
            }()),
        ]
        for (name, controller) in shots {
            writeAppKit(CaptureView(controller: controller), to: "\(directory)/capture-\(name).png", width: 480)
        }
    }

    /// The standard list on demo traffic, a step every 10 s from 0, stopped at the prompt `id` (fed its take or not),
    /// or walked to the end when `id` is nil.
    private static func captureFlow(at id: String?, fed: Bool, ledTest: Bool = false) -> CaptureFlow {
        var flow = CaptureFlow(appVersion: "1.2.0", ledTest: ledTest)
        flow.start(device: DemoCapture.deviceName, ports: DemoCapture.ports, at: 0)
        var now = 0.0
        while let prompt = flow.prompt {
            let stop = prompt.id == id
            if !stop || fed {
                for message in DemoCapture.take(for: prompt) { flow.receive(message.bytes, at: now + 1 + message.time) }
            }
            if stop {
                flow.tick(at: now + 9)
                break
            }
            now += 10
            flow.next(at: now)
        }
        return flow
    }
}


/// A clock the snapshot moves by hand, so the demo runs the same every time.
final class SnapshotClock: ControllerBridgeCore.Clock, @unchecked Sendable {
    var now: Double = 0
}

/// The snapshot's demo logs nowhere.
struct SnapshotLog: LogSink {
    func log(_ line: String) {}
}

#endif
