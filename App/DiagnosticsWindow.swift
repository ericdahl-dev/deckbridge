// The Diagnostics window (#26, redesigned in #70): MIDI monitor, LED sweep and OSC log, replacing the Python `monitor`
// and `led-sweep` commands. The lines come from ControllerBridgeCore and the lists, empty states and sweep rule from
// ControllerBridgePresentation (both tested); this is only the window, in the #34 theme.
import ControllerBridgeCore
import ControllerBridgePresentation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the Diagnostics window shows. Main-actor; the engine's sink hops here once per event, only while it is open.
@MainActor @Observable
final class DiagnosticsLog {
    private(set) var lines = DiagnosticsLines()

    /// Kept apart from `lines`, so the controls don't redraw the window on every new line (#162). Each one sets the
    /// matching DiagnosticsLines setting (#218), where the filtering is done and tested.
    var hideStreaming = true {
        didSet { lines.hideStreaming = hideStreaming }
    }
    var filterText = "" {
        didSet { lines.filter.text = filterText }
    }
    var direction = DiagnosticsDirection.both {
        didSet { lines.filter.direction = direction }
    }
    var deck: Int? {
        didSet { lines.filter.deck = deck }
    }
    private(set) var paused = false

    /// Freezes the lists, or catches them up; capture carries on either way.
    func togglePause() {
        paused.toggle()
        if paused { lines.pause() } else { lines.resume() }
    }

    func append(_ event: DiagnosticEvent) {
        let parts = event.lineParts
        let tab: DiagnosticsTab = switch event {
        case .midiIn: .monitor
        case .oscOut, .oscIn: .osc
        case .sweep: .sweep
        }
        lines.append(to: tab, message: parts.message, label: parts.label, isUnmapped: parts.isUnmapped)
    }

    /// What the window draws: the newest 2,000 of the tab's shown lines (#218).
    func drawn(_ tab: DiagnosticsTab) -> [DiagnosticsLines.Line] { lines.drawn(tab) }

    /// Every line the tab shows, as plain text to copy (#162, #218).
    func plainText(_ tab: DiagnosticsTab) -> String { lines.plainText(tab) }

    /// Everything the tab has kept, as plain text to save (#218).
    func historyText(_ tab: DiagnosticsTab) -> String { lines.historyText(tab) }

    /// Clears the tab you're on; the other lists stay.
    func clear(_ tab: DiagnosticsTab) { lines.clear(tab) }
}

struct DiagnosticsWindow: View {
    typealias Tab = DiagnosticsTab

    let log: DiagnosticsLog
    let status: BridgeStatus
    let sweeping: Bool
    /// The window opened (true) or closed (false).
    let setOpen: (Bool) -> Void
    let startSweep: (Double) -> Void
    let stopSweep: () -> Void
    /// Notes the profile drops before the monitor, such as the LC6000's heartbeat (#103), named so a quiet monitor
    /// doesn't look dead.
    var hiddenNotes: [Int] = []
    /// What the Jog display tab shows (#221).
    var jogSimulator = JogSimulatorLog()
    /// Picks the deck the jog display preview follows with no controller connected (#221); nil, the first loaded.
    var setJogPreviewDeck: (Int?) -> Void = { _ in }
    /// Starts the 10 s meter capture (#582), Debug builds only.
    var captureMeter: () -> Void = {}
    @State private var jogPreviewDeck: Int?
    @State var tab = Tab.monitor
    /// Off only for snapshots: ImageRenderer draws no ScrollView content.
    var scrolls = true
    @State private var sweepDelay = 0.6
    /// The visible tab's lines, refreshed at most 10 times a second (#162): during playback OSC lines arrive far
    /// faster, and redrawing the whole selectable list for each would stutter. Nil until the first refresh.
    @State private var visible: [DiagnosticsLines.Line]?

    var body: some View {
        let presentation = status.presentation
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Step.x3) {
                header(presentation)
                tabBar
                content
            }
            .padding(.horizontal, Theme.Step.x6 - 4)
            .padding(.vertical, Theme.Step.x4)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            StatusLineView(presentation: presentation)
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Theme.panel)
        .tint(Theme.live)
        // Only while this window is open does the bridge build anything for it.
        .onAppear { setOpen(true) }
        .onDisappear { setOpen(false) }
        .task(id: tab) {
            visible = nil
            while !Task.isCancelled {
                let lines = log.drawn(tab)
                if lines != visible { visible = lines }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: Header and tabs

    /// Which controller and deck the window is watching, with the panel's lights.
    private func header(_ presentation: StatusPresentation) -> some View {
        HStack(alignment: .center, spacing: Theme.Step.x3) {
            DeckBadgeView(deck: status.shownDeck, size: 28)
            Text(status.controller?.profile ?? "No controller")
                .font(Theme.ui(17, .medium)).tracking(-0.6)
                .foregroundStyle(Theme.text)
            Spacer(minLength: Theme.Step.x3)
            HStack(alignment: .top, spacing: Theme.Step.x6) {
                ForEach(presentation.lights, id: \.label) { StatusLightView(light: $0, size: 13) }
            }
        }
    }

    /// The three tabs as segmented pills on the left (#171), and the log's actions on the right for the visible tab.
    private var tabBar: some View {
        HStack(spacing: Theme.Step.x1) {
            SegmentedPills(options: Tab.allCases, title: \.rawValue, selection: $tab)
                .background { tabShortcuts }
            Spacer(minLength: 0)
            if tab != .jog { logActions }
        }
    }

    /// The log tabs' actions; the Jog display tab has no lines to pause, copy, save or clear.
    @ViewBuilder private var logActions: some View {
        HStack(spacing: Theme.Step.x1) {
            // Pause freezes the lists while capture carries on (#218); VoiceOver hears the new state.
            Button(log.paused ? "Resume" : "Pause") {
                log.togglePause()
                AccessibilityNotification.Announcement(log.paused ? "Log paused" : "Log resumed").post()
            }
            .buttonStyle(PillButtonStyle(kind: .quiet, small: true))
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .accessibilityLabel(log.paused ? "Resume the log" : "Pause the log")
            .accessibilityValue(log.paused ? "Paused" : "Live")
            // Copy what the tab shows, with its filter (#162, #218); Save… writes everything it has kept.
            Button("Copy visible") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.plainText(tab), forType: .string)
            }
            .buttonStyle(PillButtonStyle(kind: .quiet, small: true))
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .accessibilityLabel("Copy the visible lines of the \(tab.rawValue)")
            Button("Save…") { save(tab) }
                .buttonStyle(PillButtonStyle(kind: .quiet, small: true))
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityLabel("Save the whole \(tab.rawValue) to a file")
            Button("Clear log") { log.clear(tab) }
                .buttonStyle(PillButtonStyle(small: true))
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("Clear the \(tab.rawValue)")
            #if DEBUG
            // The debug trace file (#395): agents read it directly; the path is in the tooltip and the log.
            Button("Reveal log file") { NSWorkspace.shared.activateFileViewerSelecting([DebugTrace.shared.fileURL]) }
                .buttonStyle(PillButtonStyle(kind: .quiet, small: true))
                .help(DebugTrace.shared.fileURL.path)
                .accessibilityLabel("Reveal the debug log file in Finder")
            // #582: 10 s of Syndicate's full-rate meter stream, to a CSV beside the log, for choosing the meter's scale.
            Button("Capture meter 10 s") { captureMeter() }
                .buttonStyle(PillButtonStyle(kind: .quiet, small: true))
                .help("Writes every Mixer/CHn/Meter value for 10 s to Logs/DeckBridge; play a track first")
                .accessibilityLabel("Capture the meter stream for 10 seconds")
            #endif
        }
    }

    /// ⌘1 to ⌘4 pick the tabs (#67), from hidden buttons behind the pills.
    private var tabShortcuts: some View {
        ForEach(Array(Tab.allCases.enumerated()), id: \.element) { index, item in
            Button(item.rawValue) { tab = item }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .opacity(0).accessibilityHidden(true)
        }
    }

    // MARK: Tabs

    /// Saves the tab's whole history through the save panel (#162, #218); the user picks the place, so the sandbox
    /// allows it.
    private func save(_ tab: Tab) {
        let text = log.historyText(tab)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tab.exportFileName(appName: AppInfo.displayName)
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @ViewBuilder private var content: some View {
        // Snapshots draw once, with no task running, so they read the log directly.
        let lines = scrolls ? (visible ?? log.drawn(tab)) : log.drawn(tab)
        let connected = status.controller?.connected == true
        switch tab {
        case .monitor:
            explain("Every MIDI message from the controller, with its mapping name or UNMAPPED.")
            if let hint = Tab.hiddenNotesHint(hiddenNotes) { explain(hint) }
            filterField
            columnHeader
            LineList(lines: lines, empty: tab.emptyText(controllerConnected: connected), scrolls: scrolls)
        case .sweep:
            let availability = SweepAvailability(outputOpen: status.controller?.outputOpen == true)
            HStack(spacing: Theme.Step.x3) {
                Button(sweeping ? "Stop sweep" : "Start sweep") {
                    sweeping ? stopSweep() : startSweep(sweepDelay)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!sweeping && !availability.enabled)
                Stepper(value: $sweepDelay, in: 0.2...2.0, step: 0.1) {
                    Text("Step \(sweepDelay, specifier: "%.1f") s").font(Theme.data(12)).foregroundStyle(Theme.text)
                }
                .disabled(sweeping)
                Spacer(minLength: 0)
            }
            if let reason = availability.reason, !sweeping { explain(reason) }
            explain("Pads and ring through all 64 colors, then every other note at full, dim and off.")
            LineList(lines: lines, empty: tab.emptyText(controllerConnected: connected), scrolls: scrolls)
        case .osc:
            oscFilters
            // Syndicate subscriptions that are off, each with what it breaks, as the panel says (#211).
            if !status.missingSubscriptions.isEmpty, let help = status.help, !help.subscriptions.isEmpty {
                SubscriptionListView(help: help, size: 12)
            }
            LineList(lines: lines, empty: tab.emptyText(controllerConnected: connected), scrolls: scrolls)
        case .jog:
            explain("What the LC6000's jog display shows, drawn by the same renderer as the upload, with the beat and marker.")
            // With no controller connected, the preview follows one deck from Syndicate (#221).
            Picker("Preview follows", selection: $jogPreviewDeck) {
                Text("First loaded deck").tag(Int?.none)
                ForEach(1...4, id: \.self) { Text("Deck \($0)").tag(Int?.some($0)) }
            }
            .pickerStyle(.menu).fixedSize()
            .font(Theme.ui(12))
            .help("With no controller connected, which deck the preview shows")
            .onChange(of: jogPreviewDeck) { _, deck in setJogPreviewDeck(deck) }
            JogDisplayPane(log: jogSimulator, empty: tab.emptyText(controllerConnected: connected), animates: scrolls)
        }
    }

    /// Narrows the list to lines containing the text (#218). Display only: nothing is dropped.
    private var filterField: some View {
        TextField("Filter", text: Bindable(log).filterText, prompt: Text("Filter: TrackInfo, Deck/2…"))
            .textFieldStyle(.roundedBorder)
            .font(Theme.ui(12))
            .frame(maxWidth: 260)
            .accessibilityLabel("Filter lines")
    }

    /// The OSC log's filters (#218): text, streaming values, direction and deck.
    private var oscFilters: some View {
        HStack(spacing: Theme.Step.x3) {
            filterField
            Toggle(isOn: Bindable(log).hideStreaming) {
                Text("Hide streaming values").font(Theme.ui(12)).foregroundStyle(Theme.text)
            }
            .toggleStyle(.checkbox)
            .help("Position, BarRamp, Meter, Header/Clock, CurrentStep, SampleProgress, Progress and Time")
            Picker("Direction", selection: Bindable(log).direction) {
                ForEach(DiagnosticsDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu).fixedSize()
            .accessibilityLabel("Direction")
            Picker("Deck", selection: Bindable(log).deck) {
                Text("All decks").tag(Int?.none)
                ForEach(1...4, id: \.self) { Text("Deck \($0)").tag(Int?.some($0)) }
            }
            .pickerStyle(.menu).fixedSize()
            .accessibilityLabel("Deck")
            Spacer(minLength: 0)
        }
        .font(Theme.ui(12))
    }

    /// Lines up with the monitor's monospaced columns.
    private var columnHeader: some View {
        // Time ends at column 12, the message starts at 19 and the mapping at 70, as in the Python monitor's format.
        Text("        Time  Ch   Message" + String(repeating: " ", count: 44) + "Mapping")
            .font(Theme.data(11.5))
            .foregroundStyle(Theme.caption)
            .lineLimit(1)
            .padding(.horizontal, Theme.Step.x3)
            .accessibilityHidden(true)
    }

    /// Explanatory sentences: body text in sentence case, not captions.
    private func explain(_ text: String) -> some View {
        Text(text).font(Theme.ui(12)).foregroundStyle(Theme.caption)
    }
}

/// Lines in the data font, newest at the bottom, with hairlines between rows. An empty list says what to do.
private struct LineList: View {
    let lines: [DiagnosticsLines.Line]
    let empty: String
    var scrolls = true

    var body: some View {
        Group {
            if lines.isEmpty {
                Text(empty)
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scrolls {
                ScrollViewReader { proxy in
                    ScrollView { rows }
                        .onChange(of: lines.last?.id) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
            } else {
                rows.frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .card()
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    /// Every line in one selectable text (#162), so a drag or ⌘A selects across lines and ⌘C copies them.
    private var rows: some View {
        Text(Self.attributed(lines))
            .font(Theme.data(11.5))
            .lineSpacing(7)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Step.x3)
            .padding(.vertical, Theme.Step.x2)
            .id(Self.bottom)
    }

    static let bottom = "bottom"

    /// The lines, one per line, in the text color; UNMAPPED adds a dot and the attention color, never color alone.
    static func attributed(_ lines: [DiagnosticsLines.Line]) -> AttributedString {
        var out = AttributedString()
        for (index, line) in lines.enumerated() {
            var message = AttributedString(line.message)
            message.foregroundColor = Theme.text
            out += message
            var label = AttributedString((line.isUnmapped ? "● " : "") + line.label)
            label.foregroundColor = line.isUnmapped ? Theme.attention : Theme.text
            out += label
            if index < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }
}
