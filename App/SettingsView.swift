// The Settings window (#19), in the Syndicate theme (#34), after its design pass (#68). Not unit-tested: the settings
// model and its field-keyed problems are tested in ControllerBridgeKit; this view edits a draft and hands it to
// BridgeModel.apply.
import AppKit
import ControllerBridgeCore
import ControllerBridgePresentation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: BridgeModel
    #if DEBUG
    /// Snapshots only: one pane, without the TabView, whose toolbar a hosting view can't draw (#171).
    var snapshotTab: SettingsTab?
    /// Snapshots only: the window height to fit in, and whether a scrolling pane shows its end (#177).
    var snapshotRoom: Double?
    var snapshotScrollsToEnd = false
    #endif

    @Environment(\.openWindow) private var openWindow
    @State private var draft: BridgeSettings?
    /// The settings the draft started from, to tell the DJ's edits from changes made elsewhere (#90).
    @State private var base: BridgeSettings?
    @State private var sources: [MIDIEndpoint] = []
    /// Bumped after Controller not found?, which chooses nothing, so the Controller menu redraws (#200).
    @State private var profileMenuRedraw = 0
    @State private var destinations: [MIDIEndpoint] = []
    /// Problems from the last Apply, shown under their fields; the rest (such as the bridge not running) below.
    @State private var fieldProblems: [SettingsProblem] = []
    /// The host name being looked up by Apply, while it is (#84).
    @State private var checkingHost: String?
    @State private var otherProblems: [String] = []
    @State private var saved = false
    /// What Apply said about the save, such as needing a restart (#88).
    @State private var savedNote: String?
    @State private var startAtLogin = LoginItem.isEnabled
    @State private var loginProblem: String?
    @State private var mappingProblems: [String] = []
    @State private var mappingNote: String?
    /// The tab on show (#171). The draft lives here, above the tabs, so switching tabs never loses an edit.
    @State private var tab: SettingsTab = .controller
    @FocusState private var focused: SettingsField?
    /// Each pane's full height and the footer's, measured, so a tall pane can scroll (#177).
    @State private var paneHeights: [SettingsTab: CGFloat] = [:]
    @State private var footerHeight: CGFloat = 0

    #if DEBUG
    /// Snapshots only: a refused Apply's field problems, shown without pressing Apply.
    init(model: BridgeModel, snapshotTab: SettingsTab? = nil, problems: [SettingsProblem] = [],
         room: Double? = nil, scrolledToEnd: Bool = false) {
        self.model = model
        self.snapshotTab = snapshotTab
        snapshotRoom = room
        snapshotScrollsToEnd = scrolledToEnd
        _fieldProblems = State(initialValue: problems)
    }
    #endif

    var body: some View {
        content
            .foregroundStyle(Theme.text)
            // Brings this window, not whichever window was open before, to the front (#62).
            .background(FrontWindow())
            .onAppear(perform: load)
            .onChange(of: draft) { _, _ in saved = false }
            // A deck picked in the panel while Settings is open: keep it, and keep the DJ's own edits (#90).
            .onChange(of: model.settings) { _, new in
                guard let new, let draft, let base, new != base else { return }
                self.draft = BridgeSettings.rebased(draft: draft, base: base, onto: new)
                self.base = new
            }
    }

    @ViewBuilder
    private var content: some View {
        if let binding = Binding($draft) {
            #if DEBUG
            if let snapshotTab { page(snapshotTab, binding) } else { tabs(binding) }
            #else
            tabs(binding)
            #endif
        } else {
            emptyState.padding(Theme.Step.x4).frame(width: 440, alignment: .leading).background(Theme.panel)
        }
    }

    // MARK: Tabs (#171)

    /// The macOS Settings convention: a toolbar of tabs, one short pane each. The TabView is the window's root, so
    /// macOS draws the toolbar; each pane carries the same footer, so one Apply covers every tab.
    private func tabs(_ settings: Binding<BridgeSettings>) -> some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                page(tab, settings)
                    .tabItem { Label(tab.title, systemImage: Self.symbol(tab)) }
                    .tag(tab)
            }
        }
    }

    private func page(_ tab: SettingsTab, _ settings: Binding<BridgeSettings>) -> some View {
        let fit = SettingsPaneFit(content: Double(paneHeights[tab] ?? 0), room: room)
        return VStack(spacing: 0) {
            scrollingPane(tab, settings, fit: fit)
                .frame(height: paneHeights[tab] == nil ? nil : CGFloat(fit.height), alignment: .bottom)
                .clipped()
            footer(settings)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight = $0 }
        }
        .frame(width: 440)
        .background(Theme.panel)
        // ⌘1–4 pick the tabs; a Settings TabView doesn't add them itself.
        .background { shortcuts }
    }

    /// A pane taller than the screen allows scrolls; the footer stays pinned under it (#177).
    @ViewBuilder
    private func scrollingPane(_ tab: SettingsTab, _ settings: Binding<BridgeSettings>, fit: SettingsPaneFit) -> some View {
        let content = VStack(alignment: .leading, spacing: Theme.Step.x4) { pane(tab, settings) }
            .padding(Theme.Step.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { paneHeights[tab] = $0 }
        #if DEBUG
        // Snapshots only: the pane at its end, bottom-aligned in its clipped frame (a hosting view can't scroll).
        if snapshotScrollsToEnd {
            content.fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.vertical) { content }.scrollDisabled(!fit.scrolls).scrollIndicators(fit.scrolls ? .automatic : .hidden)
        }
        #else
        ScrollView(.vertical) { content }.scrollDisabled(!fit.scrolls).scrollIndicators(fit.scrolls ? .automatic : .hidden)
        #endif
    }

    /// The height a pane may take: the screen's visible height less the title bar and toolbar, and the footer.
    private var room: Double {
        #if DEBUG
        // A snapshot renders each pane whole unless it's given a window height.
        if snapshotTab != nil { return (snapshotRoom ?? .infinity) - Double(footerHeight) }
        #endif
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return Double(screen) - Self.windowChrome - Double(footerHeight)
    }

    /// The Settings window's title bar and toolbar of tabs, about 80 pt, plus a margin.
    private static let windowChrome = 100.0

    @ViewBuilder
    private func pane(_ tab: SettingsTab, _ settings: Binding<BridgeSettings>) -> some View {
        switch tab {
        case .controller: controllerPane(settings)
        case .decks: decksSection(settings)
        case .syndicate: syndicatePane(settings)
        case .general: generalPane(settings)
        }
    }

    private var shortcuts: some View {
        ForEach(SettingsTab.allCases, id: \.self) { tab in
            Button(tab.title) { self.tab = tab }
                .keyboardShortcut(KeyEquivalent(tab.shortcut), modifiers: .command)
                .opacity(0).accessibilityHidden(true)
        }
    }

    private static func symbol(_ tab: SettingsTab) -> String {
        switch tab {
        case .controller: "slider.horizontal.3"
        case .decks: "square.grid.2x2"
        case .syndicate: "dot.radiowaves.left.and.right"
        case .general: "gearshape"
        }
    }

    // MARK: Panes

    @ViewBuilder
    private func controllerPane(_ settings: Binding<BridgeSettings>) -> some View {
        ForEach(settings.controllers.indices, id: \.self) { index in
            controllerRows(settings, index)
        }
        section(nil) {
            switchRow("Controller LEDs", isOn: settings.ledsEnabled)
            switchRow("Show the deck on the jog display", hint: "LC6000 only.",
                      isOn: settings.jogDisplay)
            if settings.wrappedValue.jogDisplay {
                // Denon's firmware shows 15 image slots; a unit flashed with the slot 16 patch shows 16 (#425).
                // The hint ends with what was found on the unit (#456): Denon, Custom (images), or drawn.
                row("Firmware", hint: settings.wrappedValue.displayFirmware.hint(found: model.status.displayFound)) {
                    SegmentedPills(options: [DisplayFirmware.denon, .custom], title: { $0 == .denon ? "Denon" : "Custom" },
                                   selection: settings.displayFirmware)
                        .accessibilityElement(children: .contain).accessibilityLabel("Firmware")
                }
                // Syndicate sends the key as traditional text whatever its own Camelot setting is (#590).
                row("Key display", hint: "Match Syndicate's own key setting.") {
                    SegmentedPills(options: [KeyNotation.traditional, .camelot],
                                   title: { $0 == .traditional ? "Traditional" : "Camelot" },
                                   selection: settings.keyDisplay)
                        .accessibilityElement(children: .contain).accessibilityLabel("Key display")
                }
            }
            stripFaderRows(settings)
            ForEach(settings.wrappedValue.warnings, id: \.self) { note($0, color: Theme.attention) }
            if settings.wrappedValue.controllers.count < 4 {
                Button("Add controller") {
                    settings.wrappedValue.controllers.append(Self.newEntry(after: settings.wrappedValue.controllers))
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
            }
        }
        mappingSection
    }

    /// The strip of the controller in use, else the default profile's: what the fader rows show unless the DJ chose.
    private var stripFaderNeedle: Mapping.Needle? {
        let inUse = model.status.bridges.compactMap(\.profile).first
        return (model.profiles.first { $0.name == inUse } ?? model.profiles.first)?.mapping.needle
    }

    /// Shift + Needle Drop on the deck's channel fader (#609): on or off, and relative or jump, each the profile's until
    /// changed here. A strip without a touch note shows neither.
    @ViewBuilder
    private func stripFaderRows(_ settings: Binding<BridgeSettings>) -> some View {
        if let shown = settings.wrappedValue.stripFader.shown(for: stripFaderNeedle) {
            switchRow("Shift + Needle Drop moves the channel fader",
                      hint: shown.enabled
                          ? "Hold Shift and slide the strip to move the deck's fader in Syndicate's mixer"
                          : "The strip always moves through the track",
                      isOn: Binding(get: { shown.enabled }, set: { settings.wrappedValue.stripFader.enabled = $0 }))
            if shown.enabled {
                row("Fader movement", hint: shown.mode == .relative
                    ? "From where the fader is, by how far you slide. Needs Syndicate's Volume feedback"
                    : "The fader goes to where you touch the strip") {
                    SegmentedPills(options: [Mapping.Needle.ShiftFaderMode.relative, .jump],
                                   title: { $0 == .relative ? "Relative" : "Jump" },
                                   selection: Binding(get: { shown.mode }, set: { settings.wrappedValue.stripFader.mode = $0 }))
                        .accessibilityElement(children: .contain).accessibilityLabel("Fader movement")
                }
            }
        }
    }

    @ViewBuilder
    private func syndicatePane(_ settings: Binding<BridgeSettings>) -> some View {
        section("Syndicate OSC input") {
            row("Host") { field(text: settings.syndicateHost, width: 160, field: .host) }
            row("Port", hint: "Syndicate's OSC listen port") { field(value: settings.syndicatePort, field: .oscPort) }
        }
        section("OSC feedback") {
            row("Port", hint: "Syndicate's DEST IP is 127.0.0.1, PORT this number") {
                field(value: settings.feedbackPort, field: .feedbackPort)
            }
            row("Listen on") {
                Picker("Listen on", selection: settings.feedbackListen) {
                    Text("This Mac only").tag(FeedbackListen.thisMac)
                    Text("All networks").tag(FeedbackListen.allNetworks)
                }
                .labelsHidden().fixedSize()
            }
            if settings.wrappedValue.feedbackListen == .allNetworks {
                hint("For Syndicate on another Mac. macOS asks once for local-network permission; allow it, or no feedback arrives.")
            }
        }
        displayFeedSection(settings)
    }

    /// The display feed (#618): on/off, the deck panel's host and port, and what the feed is doing. Bad input is shown
    /// under its field on Apply, as the Syndicate port's is.
    @ViewBuilder
    private func displayFeedSection(_ settings: Binding<BridgeSettings>) -> some View {
        section("Display feed") {
            hint("Sends the deck in front to a deck panel on your network, or plugged into this Mac.")
            switchRow("Send the display feed", isOn: settings.displayFeed.enabled)
            if settings.wrappedValue.displayFeed.enabled {
                row("Host", hint: "The panel's IP address, shown on its waiting screen") {
                    field(text: settings.displayFeed.host, width: 160, field: .displayFeedHost)
                }
                row("Port", hint: "The panel's port, shown on its waiting screen") {
                    field(value: settings.displayFeed.port, field: .displayFeedPort)
                }
            }
            // The applied setting's status, read again each second: a feed that can't send never fails silently.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let status = model.displayFeedStatus
                note(status.text, color: status.isProblem ? Theme.error : Theme.caption)
            }
            // The USB cable (#667): no Wi-Fi setup on the panel. Off by default, apart from the switch above.
            switchRow("Send over the USB cable", isOn: settings.displayFeed.cable)
            if settings.wrappedValue.displayFeed.cable {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let status = model.cableFeedStatus
                    note(status.text, color: status.isProblem ? Theme.error : Theme.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func generalPane(_ settings: Binding<BridgeSettings>) -> some View {
        section("Login") {
            row("Appearance") {
                // Syndicate's LIGHT MODE can't be read over OSC, so pick it here to match (#127).
                Picker("Appearance", selection: settings.appearance) {
                    Text("Match macOS").tag(Appearance.matchMacOS)
                    Text("Dark").tag(Appearance.dark)
                    Text("Light").tag(Appearance.light)
                }
                .labelsHidden().fixedSize()
            }
            switchRow("Start at login", isOn: $startAtLogin)
                .onChange(of: startAtLogin) { _, enabled in setLogin(enabled) }
            if let loginProblem { note(loginProblem, color: Theme.error) }
        }
        // What to set on Syndicate's side is in the guide, reachable from here as well as the panel (#66 item 6).
        Button("Setup Guide…") { SetupGuideWindow.open(openWindow) }.buttonStyle(PillButtonStyle(kind: .quiet))
    }

    private var mappingSection: some View {
        section("Mapping") {
            row("In use") { note(model.status.mappingInUse) }
            HStack(spacing: Theme.Step.x2) {
                Button("Import…") { importMapping() }.buttonStyle(PillButtonStyle(small: true))
                Button("Export…") { exportMapping() }.buttonStyle(PillButtonStyle(small: true))
                Button("Reset") {
                    let problem = model.resetMapping()
                    mappingProblems = problem.map { [$0] } ?? []
                    mappingNote = problem == nil ? "Back to the bundled mapping." : nil
                }
                .buttonStyle(PillButtonStyle(small: true))
                .help("Go back to the bundled mapping")
            }
            if let mappingNote { note(mappingNote) }
            ForEach(mappingProblems, id: \.self) { note($0, color: Theme.error) }
        }
    }

    // MARK: Footer

    /// Revert and Apply, shared by every tab (#171). A refusal lists its problems here, each after its tab's name.
    private func footer(_ settings: Binding<BridgeSettings>) -> some View {
        let dirty = settings.wrappedValue != model.settings
        let refusal = SettingsRefusal(fields: fieldProblems, other: otherProblems)
        return VStack(alignment: .leading, spacing: Theme.Step.x2) {
            ForEach(refusal.footer, id: \.self) { note($0, color: Theme.error) }
            HStack(spacing: Theme.Step.x2) {
                Text(checkingHost.map { "Checking \($0)…" } ?? (saved && !dirty ? (savedNote ?? "Saved.") : "Changes apply when you press Apply."))
                    .font(Theme.ui(Theme.Size.body)).foregroundStyle(Theme.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Revert") { load() }.buttonStyle(PillButtonStyle()).disabled(!dirty)
                Button { apply(settings.wrappedValue) } label: {
                    HStack(spacing: Theme.Step.x1) { Text("Apply"); Text("›").accessibilityHidden(true) }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!dirty || checkingHost != nil)
            }
        }
        .padding(.horizontal, Theme.Step.x4)
        .padding(.vertical, Theme.Step.x3)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// One controller entry: its deck (applied at once, like the panel's picker), devices and channel (#25, #68).
    private func controllerRows(_ settings: Binding<BridgeSettings>, _ index: Int) -> some View {
        // Bounds-checked: right after a removal, SwiftUI can still read the removed row once.
        let controller = Binding<ControllerSettings>(
            get: { settings.wrappedValue.controllers.indices.contains(index) ? settings.wrappedValue.controllers[index] : Self.newEntry(after: []) },
            set: { if settings.wrappedValue.controllers.indices.contains(index) { settings.wrappedValue.controllers[index] = $0 } }
        )
        let following = !model.layers.isEmpty && controller.wrappedValue.followLayers != false
        return section(settings.wrappedValue.controllers.count > 1 ? "Controller \(index + 1)" : "Controller") {
            if !model.layers.isEmpty {
                // The LC6000's own Shift + deck select steps channel 1-4, so it picks deck 1-4 itself (#79).
                switchRow("Follow controller layers", hint: following ? "Shift + deck select on the controller picks Deck 1-4" : nil,
                          isOn: Binding(get: { following }, set: { controller.wrappedValue.followLayers = $0 }))
            }
            if !following { deckRow(controller.wrappedValue.deck, index) }
            row("MIDI input") { devicePicker(selection: controller.input, devices: sources) }
            fieldError(.device(controller: index))
            profileRow(settings, controller.wrappedValue)
            row("MIDI output") { devicePicker(selection: controller.output, devices: destinations) }
            // Deck and channel come from the controller's layers while it follows them (#79).
            if !following { channelRow(controller, index) }
            if settings.wrappedValue.controllers.count > 1 {
                Button("Remove controller \(index + 1)") { settings.wrappedValue.controllers.remove(at: index) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            }
        }
    }

    private func deckRow(_ deck: Int, _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Step.x1) {
            row("Deck") {
                DeckPicker(deck: deck, state: model.status.presentation.deckPicker, problem: model.status.deckProblem, size: 28) { deck in
                    // The deck applies at once, as in the panel. A saved change reaches the draft through the rebase on
                    // model.settings; a refused one leaves the draft alone and shows why (#90).
                    model.setDeck(deck, controller: index)
                }
            }
            fieldError(.deck(controller: index))
        }
    }

    private func channelRow(_ controller: Binding<ControllerSettings>, _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Step.x1) {
            row("Channel") {
                Picker("Channel", selection: controller.channel) {
                    Text("From the profile").tag(Int?.none)
                    ForEach(1...16, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                .labelsHidden().fixedSize()
            }
            fieldError(.channel(controller: index))
        }
    }

    // MARK: Pieces

    /// A grouped card under a mono label, as in System Settings and the site (#171).
    private func section(_ title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Step.x2) {
            if let title {
                Text(title).font(Theme.labelFont).foregroundStyle(Theme.caption).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: Theme.Step.x3) { content() }
                .padding(Theme.Step.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    /// The label on the left with its hint under it, the control on the right.
    private func row(_ label: String, hint text: String? = nil, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Step.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.ui(Theme.Size.emphasis))
                if let text { hint(text) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }

    /// A row that is one switch: the switch's own words are the row's label (#171). On reads as live green (#68).
    private func switchRow(_ title: String, hint text: String? = nil, isOn: Binding<Bool>) -> some View {
        row(title, hint: text) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Self.on)
        }
    }

    /// The Controller picker (#200): Automatic or a profile, saved for the card's device on Apply, and
    /// Controller not found?, which opens the capture window for that device.
    private func profileRow(_ settings: Binding<BridgeSettings>, _ entry: ControllerSettings) -> some View {
        let single = settings.wrappedValue.controllers.count == 1
        let picker = ProfilePicker(
            chosenInput: entry.input?.name,
            connectedDevice: single ? model.status.bridges.compactMap(\.device).first : nil,
            // Only the device the panel highlights, with no controller connected, as before #329: this entry is unchanged.
            unsupported: model.status.otherDevices.highlighted?.label,
            profiles: model.profiles.map { (id: $0.id, name: $0.name) },
            choices: settings.wrappedValue.profileChoices
        )
        let selection = Binding<String?>(
            get: { picker.selected },
            set: { id in
                if id == Self.notFoundTag {
                    model.captureRequest.device = picker.device
                    openWindow(id: CaptureWindow.id)
                    // Nothing was chosen: redraw the menu so it shows the saved choice again, not this item.
                    profileMenuRedraw += 1
                } else if let device = picker.device {
                    settings.wrappedValue.profileChoices[device] = id
                }
            }
        )
        return row("Controller", hint: picker.hint) {
            Picker("Controller", selection: selection) {
                ForEach(picker.options, id: \.self) { Text($0.title).tag($0.id) }
                Divider()
                Text(ProfilePicker.notFoundTitle).tag(String?.some(Self.notFoundTag))
            }
            .labelsHidden()
            .fixedSize()
            .id(profileMenuRedraw)
            .disabled(!picker.enabled)
        }
    }

    /// The picker's tag for Controller not found?, which opens the capture window instead of choosing.
    private static let notFoundTag = "controller-not-found"

    private func devicePicker(selection: Binding<MIDIEndpoint?>, devices: [MIDIEndpoint]) -> some View {
        Picker("Device", selection: selection) {
            Text("Automatic").tag(MIDIEndpoint?.none)
            ForEach(devices) { Text($0.name).tag(MIDIEndpoint?.some($0)) }
            // A saved device that isn't plugged in stays selectable, so the choice isn't lost.
            if let chosen = selection.wrappedValue, !devices.contains(chosen) {
                Text("\(chosen.name) (not connected)").tag(MIDIEndpoint?.some(chosen))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220, alignment: .trailing)
    }

    private func field(text: Binding<String>, width: CGFloat, field: SettingsField) -> some View {
        VStack(alignment: .trailing, spacing: Theme.Step.x1) {
            TextField("", text: text).labelsHidden().font(Theme.data(Theme.Size.emphasis)).frame(width: width)
                .focused($focused, equals: field)
                .overlay(errorBorder(field))
            fieldError(field)
        }
    }

    private func field(value: Binding<Int>, field: SettingsField) -> some View {
        VStack(alignment: .trailing, spacing: Theme.Step.x1) {
            TextField("", value: value, format: .number.grouping(.never)).labelsHidden()
                .font(Theme.data(Theme.Size.emphasis)).frame(width: 80)
                .focused($focused, equals: field)
                .overlay(errorBorder(field))
            fieldError(field)
        }
    }

    /// A 1 pt error border on a field with a problem (#68).
    @ViewBuilder
    private func errorBorder(_ field: SettingsField) -> some View {
        if fieldProblems.contains(where: { $0.field == field }) {
            RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.error, lineWidth: 1)
        }
    }

    // MARK: Decks (#123)

    /// The deck colors: Syndicate's (cue palette slots 1, 3, 5 and 7) or the DJ's own, each with the LC6000's version.
    private func decksSection(_ settings: Binding<BridgeSettings>) -> some View {
        section("Decks") {
            switchRow("Use Syndicate's deck colors",
                      hint: settings.wrappedValue.followSyndicateDeckColors
                          ? "Cue palette slots 1, 3, 5 and 7 in Syndicate's CUE COLORS, as they change"
                          : "Your own colors, for the app's badges and the LC6000's ring",
                      isOn: settings.followSyndicateDeckColors)
            // #530: Denon's own color message gives the ring (and, later, the pads) their exact color. Off is the way
            // back to the 64-color table, for a top panel firmware that doesn't take it.
            switchRow("Exact colors on the LC6000",
                      hint: settings.wrappedValue.colorMessages
                          ? "The ring shows each deck's exact color"
                          : "The ring uses the LC6000's 64 colors",
                      isOn: settings.colorMessages)
            // #532: how bright the exact-color LEDs (the ring, and the pads with #531) are; the user's pick, 10% to 100%
            // in tens. Only with exact colors on: the 64-color table and the single-color buttons don't take it.
            if settings.wrappedValue.colorMessages {
                row("Light brightness", hint: "How bright the ring and pads are: dim them in a dark room") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { Double(settings.wrappedValue.lightBrightness) },
                            set: { settings.wrappedValue.lightBrightness = LightBrightness.snapped(Int($0.rounded())) }
                        ), in: 10...100, step: 10)
                            .frame(width: 160)
                            .accessibilityLabel("Light brightness")
                            .accessibilityValue(LightBrightness.label(settings.wrappedValue.lightBrightness))
                        Text(LightBrightness.label(settings.wrappedValue.lightBrightness))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            // Vivid keeps a color's hue on the LC6000's 64 colors; Exact rounds each channel (#151). With exact colors on,
            // only a held pad still takes the table, until the pads move to the color message too (#531).
            row("Ring colors", hint: settings.wrappedValue.colorMessages
                ? "For a held pad; the ring shows exact colors"
                : settings.wrappedValue.ringColors == .vivid
                    ? "Strong colors on the ring and a held pad, keeping each hue"
                    : "Each channel rounded, as the pads' cue colors are; softer colors look paler") {
                SegmentedPills(options: [RingColors.vivid, .exact], title: { $0 == .vivid ? "Vivid" : "Exact" },
                               selection: settings.ringColors)
                    .accessibilityElement(children: .contain).accessibilityLabel("Ring colors")
            }
            ForEach(1...4, id: \.self) { deck in deckColorRow(settings, deck) }
            if !settings.wrappedValue.followSyndicateDeckColors {
                Button("Reset to default") { settings.wrappedValue.customDeckColors = .defaults }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            }
            // #363, #366: the jump and paused seeks turn the deck's quantize off and back to Use Global; Syndicate doesn't say what it was.
            hint("Shift + a hot cue pad on a stopped deck jumps to the cue at once, and the jog and Needle Drop seek a paused deck exactly. For those moves DeckBridge turns that deck's quantize off in Syndicate, then sets it to Use Global, so a deck's own quantize setting is reset.")
        }
    }

    private func deckColorRow(_ settings: Binding<BridgeSettings>, _ deck: Int) -> some View {
        // What the LC6000's ring will show: rgb222, so a subtle color may come out plainer.
        let shown = settings.wrappedValue.followSyndicateDeckColors ? deckColors[deck] : settings.wrappedValue.customDeckColors[deck]
        return VStack(alignment: .leading, spacing: Theme.Step.x1) {
            HStack(spacing: Theme.Step.x3) {
                DeckBadgeView(deck: deck, size: 24)
                if !settings.wrappedValue.followSyndicateDeckColors {
                    ColorPicker("Deck \(deck) color", selection: Self.color(settings, deck: deck), supportsOpacity: false)
                        .labelsHidden()
                }
                Spacer(minLength: 0)
                hint("On the LC6000")
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .fill(Color(RGB(deckColor: settings.wrappedValue.colorMessages
                        // The color message (#530): the deck's own color.
                        ? (shown ?? [0, 0, 0])
                        // rgb222, the LC6000's table, as the label says and #197 planned (#313): not a profile lookup.
                        : DeckColors.ledPreview(shown ?? [0, 0, 0], mode: settings.wrappedValue.ringColors, table: .rgb222))))
                    .frame(width: 26, height: 26)
                    .accessibilityLabel("Deck \(deck) on the LC6000")
            }
            fieldError(.deckColor(deck: deck))
        }
    }

    @Environment(\.deckColors) private var deckColors

    /// A custom deck color as a SwiftUI color, written back as [r, g, b] in sRGB.
    private static func color(_ settings: Binding<BridgeSettings>, deck: Int) -> Binding<Color> {
        Binding(
            get: { Color(RGB(deckColor: settings.wrappedValue.customDeckColors[deck] ?? [0, 0, 0])) },
            set: { color in
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                settings.wrappedValue.customDeckColors.rgb[deck] = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
                    .map { Int(($0 * 255).rounded()) }
            }
        )
    }

    /// The problems that belong to a field, right under it (#68).
    @ViewBuilder
    private func fieldError(_ field: SettingsField) -> some View {
        ForEach(fieldProblems.filter { $0.field == field }, id: \.message) { note($0.message, color: Theme.error) }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(Theme.ui(Theme.Size.caption)).foregroundStyle(Theme.caption).fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String, color: Color = Theme.caption) -> some View {
        Text(text).font(Theme.ui(Theme.Size.body)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    /// With the bridge stopped there is nothing to set: say why in plain words, and offer Diagnostics (#68).
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Nothing to set").font(Theme.ui(Theme.Size.title, .bold)).foregroundStyle(Theme.text)
            note(model.status.help?.text ?? "The bridge didn't start. Quit and reopen it.")
            Button("Diagnostics…") {
                NSApp.activate()
                openWindow(id: "diagnostics")
            }
            .buttonStyle(PillButtonStyle())
        }
    }

    /// A switch that's on reads as live, in Syndicate's green, not the system blue (#68). Toggles only: on pickers the
    /// tint would color their text green and read as "live".
    private static let on = Theme.live

    /// A new entry on the first deck no controller drives yet, with automatic devices.
    private static func newEntry(after entries: [ControllerSettings]) -> ControllerSettings {
        let used = Set(entries.map(\.deck))
        return ControllerSettings(deck: (1...4).first { !used.contains($0) } ?? 1, input: nil, output: nil)
    }

    // MARK: Mapping (#24)

    private func importMapping() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a mapping file. A bad file is refused, and the current mapping keeps running."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mappingProblems = model.importMapping(from: url)
        mappingNote = mappingProblems.isEmpty
            ? model.lastImportNote ?? "Imported \(url.lastPathComponent)."
            : "Not imported: fix these and try again."
    }

    private func exportMapping() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(model.profiles.first?.id ?? "mapping").json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportMapping(to: url)
            mappingProblems = []
            mappingNote = "Exported \(url.lastPathComponent)."
        } catch {
            mappingProblems = ["Couldn't export: \(error.localizedDescription)"]
        }
    }

    // MARK: Actions

    private func load() {
        draft = model.settings
        base = model.settings
        sources = model.sources
        destinations = model.destinations
        #if DEBUG
        // A snapshot keeps the problems it was given.
        if snapshotTab == nil { fieldProblems = [] }
        #else
        fieldProblems = []
        #endif
        otherProblems = []
        saved = false
        startAtLogin = LoginItem.isEnabled
        // A menu-bar app has no Dock icon, so its windows open behind the front app unless it activates.
        NSApp.activate()
    }

    private func apply(_ settings: BridgeSettings) {
        // Field problems are checked here, so they show under their fields; apply checks them all again.
        let problems = settings.fieldProblems
        guard problems.isEmpty else {
            refuse(fields: problems, other: [])
            return
        }
        // A host name is looked up off the main actor (#84): the window stays usable and says it's checking.
        checkingHost = BridgeSettings.isIPv4(settings.syndicateHost.trimmingCharacters(in: .whitespaces))
            ? nil : settings.syndicateHost.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            defer { checkingHost = nil }
            do throws(SettingsError) {
                savedNote = try await model.apply(settings)
                draft = model.settings
                base = model.settings
                fieldProblems = []
                otherProblems = []
                saved = true
            } catch {
                switch error {
                case .invalid(let list): refuse(fields: [], other: list)
                case .fields(let list): refuse(fields: list, other: [])
                }
                saved = false
            }
        }
    }

    /// A refused Apply (#171): show the problems, go to the leftmost tab with one, tell VoiceOver, and focus the field.
    private func refuse(fields: [SettingsProblem], other: [String]) {
        fieldProblems = fields
        otherProblems = other
        let refusal = SettingsRefusal(fields: fields, other: other)
        if let target = refusal.tab { tab = target }
        AccessibilityNotification.Announcement(refusal.announcement).post()
        // The field is on screen only once the tab has switched, so focus it on the next turn. Only the host and the
        // two ports are text fields; for a picker the footer and the announcement say where to look.
        Task { @MainActor in focused = refusal.focus }
    }

    private func setLogin(_ enabled: Bool) {
        guard enabled != LoginItem.isEnabled else { return }
        do {
            try LoginItem.set(enabled)
            loginProblem = nil
        } catch {
            loginProblem = "Couldn't change start at login: \(error.localizedDescription)"
            startAtLogin = LoginItem.isEnabled
        }
    }
}

/// Brings the window this view is in to the front once it's on screen (#62): a menu-bar app's windows otherwise open
/// behind the front app, and "the first visible window" could be Diagnostics, not this one.
private struct FrontWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.makeKeyAndOrderFront(nil) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
