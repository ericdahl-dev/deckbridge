// The menu-bar panel, in the Syndicate-style theme (#34).
import ControllerBridgeCore
import ControllerBridgePresentation
import SwiftUI

extension BridgeStatus {
    /// The first controller, as the Coordinator reports it (#20, #43).
    var controller: ControllerStatus? { bridges.first }

    /// MIDI sources no controller profile matches (#43), leaving out a known controller's other ports (#200).
    var unmatchedDevices: [DeviceStatus] { devices.filter { $0.profile == nil && $0.partOf == nil } }

    var shownDeck: Int { controller?.deck ?? deck }

    /// Unmatched devices: a quiet gray list, or one orange NO PROFILE row when no controller is connected (#43).
    /// Each one that isn't a virtual port is offered Help add it… either way (#329).
    var otherDevices: OtherDevices {
        OtherDevices(
            unmatched: unmatchedDevices.map(\.name),
            ownPorts: devices.compactMap { device in device.partOf.map { (name: device.name, of: $0) } },
            controllerConnected: controller?.connected == true
        )
    }

    /// The status in Syndicate's words.
    var presentation: StatusPresentation { StatusPresentation(bridgeState) }

    /// Why the LEDs are dark, if they might be (#27).
    var help: HelpMessage? { HelpMessage(bridgeState) }

    /// The setup guide, naming the connected controller's profile when there is one.
    var setupGuide: SetupGuide {
        let port = switch feedback {
        case .listening(let port), .portInUse(let port): port
        case .starting, .failed: 9096
        }
        return SetupGuide(controller: controller?.profile, oscPort: oscPort, feedbackPort: port,
                          subscriptions: requiredSubscriptions.map(\.syndicateName))
    }

    var bridgeState: BridgeState {
        let feedback: BridgeState.Feedback = switch self.feedback {
        case .starting: .starting
        // The listener is up; whether Syndicate is answering is the Coordinator's call (#21).
        case .listening(let port):
            switch syndicateFeedback {
            case .waiting: .waiting(port: port)
            case .live: noDeckData ? .noDeckData(port: port) : .live(port: port)
            case .stale: .stopped(port: port)
            }
        case .portInUse(let port): .portInUse(port: port)
        case .failed: .failed
        }
        // One unit following its layers shows as one controller, on its active layer's deck (#79).
        let folded = CoordinatorStatus(controllers: bridges).collapsingLayers().controllers
        let entries = folded.map {
            BridgeState.ControllerEntry(controller: Self.controllerState($0), deck: $0.deck, lastEvent: $0.lastEvent,
                                        followsLayers: $0.followsLayers)
        }
        let first = entries.first
        var state = BridgeState(
            controller: first?.controller ?? .notConnected, feedback: feedback, deck: first?.deck ?? deck,
            stopped: problem != nil, lastDropout: lastDropoutTime, master: self.controller?.master == true, demo: demo,
            lastEvent: first?.lastEvent, others: Array(entries.dropFirst()), stopReason: stopReason,
            followsLayers: first?.followsLayers ?? false, missingSubscriptions: missingSubscriptions.map { MissingSubscription(name: $0.syndicateName, breaks: $0.breaks) },
            requiredSubscriptions: requiredSubscriptions.map(\.syndicateName)
        )
        state.otherHost = otherHost
        return state
    }

    /// The panel's controller state, by the tested mapping in Presentation (#91).
    static func controllerState(_ bridge: ControllerStatus) -> BridgeState.Controller {
        BridgeState.Controller(
            connected: bridge.connected, profile: bridge.profile, lastProfile: bridge.lastProfile,
            lastDisconnect: bridge.lastDisconnect.map(Self.disconnect)
        )
    }

    /// Core's reason, one to one.
    static func disconnect(_ reason: DisconnectReason) -> BridgeState.Disconnect {
        switch reason {
        case .unplugged: .unplugged
        case .sendFailed: .sendFailed
        case .inputFailed: .inputFailed
        case .deviceChanged: .deviceChanged
        case .removed: .removed
        case .stopped: .stopped
        }
    }
}

enum AppInfo {
    /// The display name (#29). Every window reads it from here.
    static let displayName = "DeckBridge"
}

struct StatusPanel: View {
    let status: BridgeStatus
    /// Turns the demo controller (#64) on or off.
    var setDemo: (Bool) -> Void = { _ in }
    /// The deck picker (#66): a deck for the controller at an index.
    var setDeck: (_ deck: Int, _ controller: Int) -> Void = { _, _ in }
    /// Opens the capture window with a device preselected (#200).
    var helpAdd: (String) -> Void = { _ in }
    @Environment(\.openWindow) private var openWindow
    /// Quit asks inside the panel while feedback is live (#131): a dialog on a menu-bar window may never show.
    @State var quitFlow = QuitFlow()

    var body: some View {
        let presentation = status.presentation
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Step.x4) {
                blocks(presentation)
                StatusCard(status: status, presentation: presentation, helpAdd: helpAdd)
                if let dropout = presentation.lastDropout {
                    CaptionValue(caption: dropout.caption, value: dropout.value)
                }
                if let help = status.help { HelpBlock(help: help, problem: status.problem) }
                actions
                footer(presentation)
            }
            .padding(Theme.Step.x4)
            .padding(.top, 2)
            .background(Theme.panel)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            StatusLineView(presentation: presentation)
        }
        .frame(width: 360)
        .background(Theme.panel)
        // ⌘Q quits without asking: a DJ pressing it means it (#131).
        .background {
            Button("Quit now") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q").opacity(0).accessibilityHidden(true)
        }
        .onDisappear { quitFlow.panelClosed() }
    }

    /// One block per controller: its name, its last event and its deck picker (#66, #25).
    private func blocks(_ presentation: StatusPresentation) -> some View {
        ForEach(Array(presentation.blocks.enumerated()), id: \.offset) { index, block in
            if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
            ControllerBlockView(
                block: block, showsLight: presentation.blocks.count > 1, picker: presentation.deckPicker,
                deckProblem: status.deckProblem,
                setDeck: { setDeck($0, index) }
            )
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Step.x2) {
            SettingsLink { Text("Settings…") }.buttonStyle(PillButtonStyle(fills: true)).keyboardShortcut(",")
            Button("Diagnostics…") {
                // A menu-bar (LSUIElement) app must come forward first, or the window opens behind.
                NSApp.activate()
                openWindow(id: "diagnostics")
            }
            .buttonStyle(PillButtonStyle(fills: true))
            .keyboardShortcut("d")
        }
    }

    /// Quiet controls: the guide, the demo, and Quit kept apart from the main buttons (#66); or Quit's question (#131).
    @ViewBuilder private func footer(_ presentation: StatusPresentation) -> some View {
        if quitFlow.confirming {
            QuitQuestion(quitFlow: $quitFlow)
        } else {
            HStack(spacing: 0) {
                Button("Setup guide") { SetupGuideWindow.open(openWindow) }.buttonStyle(PillButtonStyle(kind: .quiet, small: true))
                // Not while stopped: there's no pipe to switch the demo on with (#88).
                if presentation.showsDemoToggle {
                    Button("Demo controller: \(status.demo ? "On" : "Off")") { setDemo(!status.demo) }
                        .buttonStyle(PillButtonStyle(kind: .quiet, small: true, color: status.demo ? Theme.attention : nil))
                }
                Spacer(minLength: 0)
                Button("Quit") {
                    if quitFlow.pressQuit(asks: presentation.quitAsks) == .quitNow { NSApplication.shared.terminate(nil) }
                }
                .buttonStyle(PillButtonStyle(kind: .quiet, small: true))
            }
            .padding(.horizontal, -Theme.Step.x2)
        }
    }
}

/// The lights on a card, the unmatched devices, and the ports under a hairline (#171).
private struct StatusCard: View {
    let status: BridgeStatus
    let presentation: StatusPresentation
    var helpAdd: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Two lights to a row; a third or fourth (BRIDGE STOPPED, DEMO, MASTER) wraps to the next.
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: Theme.Step.x3) {
                // With several controllers, each block shows its own CONTROLLER light; the card keeps the rest.
                ForEach(presentation.lights.filter { presentation.blocks.count == 1 || $0.kind != .controller }, id: \.label) {
                    StatusLightView(light: $0)
                }
                if let master = presentation.master { StatusLightView(light: master) }
            }
            .padding(Theme.Step.x3)
            devices
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // The ports, in one quiet line; the deck is in the picker (#66).
            Text("OSC → \(String(status.oscPort)) · Feedback ← \(feedbackPort)")
                .font(Theme.data(11)).foregroundStyle(Theme.caption)
                .padding(.horizontal, Theme.Step.x3).padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var devices: some View {
        let others = status.otherDevices
        if others.highlighted != nil || others.summary != nil {
            VStack(alignment: .leading, spacing: Theme.Step.x2) {
                if let highlighted = others.highlighted {
                    StatusLightView(light: highlighted)
                        .help(status.unmatchedDevices.first { $0.name == highlighted.label }?.note ?? "")
                }
                // One per unmatched device, each opening the capture with its own device preselected (#329).
                ForEach(Array(others.offers.enumerated()), id: \.offset) { entry in
                    CaptureOfferRow(offer: entry.element) { helpAdd(entry.element.device) }
                }
                if let summary = others.summary { OtherDevicesList(summary: summary, rows: others.rows) }
            }
            .padding([.horizontal, .bottom], Theme.Step.x3)
        }
    }

    private var feedbackPort: String {
        switch status.feedback {
        case .listening(let port), .portInUse(let port): "\(port)"
        case .starting, .failed: "–"
        }
    }
}

/// Why the LEDs are dark, in plain words, with the guide and the raw error to copy (#27, #66).
private struct HelpBlock: View {
    let help: HelpMessage
    let problem: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Step.x2) {
            Text("Why no LEDs?").font(Theme.labelFont).foregroundStyle(Theme.caption)
            if help.subscriptions.isEmpty {
                Text(help.text).font(Theme.ui(13)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Subscriptions off: a list, not a paragraph (#261).
                SubscriptionListView(help: help)
            }
            HStack(spacing: Theme.Step.x2) {
                if help.showsGuide {
                    Button("Setup guide") { SetupGuideWindow.open(openWindow) }.buttonStyle(PillButtonStyle(small: true))
                }
                // The raw error is for a bug report, not the panel body (#66).
                if let problem {
                    Button("Copy details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(problem, forType: .string)
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet, small: true))
                    .padding(.leading, help.showsGuide ? 0 : -Theme.Step.x2)
                }
            }
        }
    }
}

/// Quit pressed while feedback is live: the question in the panel itself. Return quits, Esc cancels (#131).
private struct QuitQuestion: View {
    @Binding var quitFlow: QuitFlow

    var body: some View {
        HStack(spacing: Theme.Step.x2) {
            Text(QuitFlow.question).font(Theme.ui(13)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Cancel") { quitFlow.cancel() }
                .buttonStyle(PillButtonStyle(small: true)).keyboardShortcut(.cancelAction)
            Button("Quit") { if quitFlow.confirm() == .quitNow { NSApplication.shared.terminate(nil) } }
                .buttonStyle(PillButtonStyle(small: true)).keyboardShortcut(.defaultAction)
        }
    }
}

/// One controller's block: its name, its last event, its light (after the first) and its deck picker.
struct ControllerBlockView: View {
    let block: ControllerBlock
    let showsLight: Bool
    /// Usable, off with a reason (demo mode), or hidden (stopped), from the tested presentation (#90).
    let picker: DeckPickerState
    /// A refused deck change, shown under the picker (#90).
    let deckProblem: String?
    let setDeck: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Step.x3) {
            HStack(alignment: .top, spacing: Theme.Step.x3) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(block.header.title).font(Theme.ui(17, .medium)).tracking(-0.6).foregroundStyle(Theme.text).lineLimit(1)
                    if let subtitle = block.header.subtitle {
                        Text(subtitle).font(Theme.ui(13)).foregroundStyle(Theme.caption).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if showsLight { StatusLightView(light: block.light, size: 13) }
            }
            if let note = block.deckNote {
                // The controller's own layers pick the deck (#79): show it, with no picker to fight it.
                HStack(spacing: Theme.Step.x3) {
                    DeckBadgeView(deck: block.deck)
                    Text(note).font(Theme.ui(13)).foregroundStyle(Theme.caption)
                }
                .accessibilityElement(children: .combine)
            } else if picker != .hidden {
                DeckPicker(deck: block.deck, state: picker, problem: deckProblem, setDeck: setDeck)
            }
        }
        // One container per controller, named with its number, so VoiceOver can tell two blocks apart (#89).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.accessibilityLabel)
    }
}

/// The four Syndicate decks as badges (#66): the current one in its deck color with a bar under it, the others tonal.
/// A click switches.
struct DeckPicker: View {
    let deck: Int
    var state: DeckPickerState = .enabled
    var problem: String?
    var size: CGFloat = 34
    let setDeck: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Step.x2) {
            badges
                .disabled(state != .enabled)
                .opacity(state == .enabled ? 1 : 0.4)
            if case .disabled(let reason) = state {
                Text(reason).font(Theme.ui(12)).foregroundStyle(Theme.caption)
            }
            if let problem {
                Text(problem).font(Theme.ui(12)).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var badges: some View {
        HStack(spacing: Theme.Step.x2) {
            ForEach(1...4, id: \.self) { number in
                Button { setDeck(number) } label: { badge(number) }
                    .buttonStyle(CaptionButtonStyle())
                    .accessibilityLabel("Deck \(number)")
                    .accessibilityAddTraits(number == deck ? .isSelected : [])
            }
        }
        // Room for the selected bar under the badges.
        .padding(.bottom, 6)
    }

    @ViewBuilder private func badge(_ number: Int) -> some View {
        if number == deck {
            // The deck color plus a bar: selection is never a fill alone (#67).
            DeckBadgeView(deck: number, size: size)
                .overlay(alignment: .bottom) {
                    Capsule().fill(Color(\.selectedBar)).frame(height: 2).padding(.horizontal, 4).offset(y: 6)
                }
        } else {
            Text("\(number)")
                .font(Theme.data(size * 0.44, .medium))
                .foregroundStyle(Theme.caption)
                .frame(width: size, height: size)
                .background(Theme.buttonRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        }
    }
}

/// The quiet list of MIDI devices no profile matches: one muted line that expands to the names.
struct OtherDevicesList: View {
    let summary: String
    let rows: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    Text(summary).font(Theme.labelFont)
                }
                .foregroundStyle(Theme.caption)
            }
            .buttonStyle(CaptionButtonStyle())
            .accessibilityLabel("\(summary), \(expanded ? "expanded" : "collapsed")")
            if expanded {
                ForEach(rows, id: \.self) { row in
                    Text(row).font(Theme.ui(12)).foregroundStyle(Theme.caption).padding(.leading, 12)
                }
            }
        }
    }
}

/// "DDJ-FLX4 isn't supported yet." with Help add it… (#200): under its NO PROFILE row, or above the gray list while a
/// controller is connected (#329).
private struct CaptureOfferRow: View {
    let offer: CaptureOffer
    let action: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: Theme.Step.x2) {
            Text(offer.text).font(Theme.ui(12)).foregroundStyle(Theme.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(offer.action) {
                action()
                openWindow(id: CaptureWindow.id)
            }
            .buttonStyle(PillButtonStyle(small: true))
        }
    }
}
