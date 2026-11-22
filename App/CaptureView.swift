// The guided "Help add a controller" window (#186): a thin view over the Kit's CaptureFlow. Bodies stay small for the
// CI Xcode 26.6 optimizer (#65).
import ControllerBridgeCapture
import ControllerBridgeCore
import SwiftUI

enum CaptureWindow {
    static let id = "capture"
    static let title = "Help Add a Controller"
}

/// The window's root: makes the controller, lists the ports when it opens, and gives the bridge back when it closes.
struct CaptureWindowRoot: View {
    let model: BridgeModel
    @State private var controller: CaptureController?

    var body: some View {
        Group {
            if let controller { CaptureView(controller: controller) } else { Theme.panel.frame(width: 480, height: 360) }
        }
        .onAppear {
            // A fresh capture each time the window opens, and any earlier one gives its controller back.
            controller?.end()
            let made = CaptureController(setCapture: model.setCapture(source:))
            made.refresh(sources: model.sources, destinations: model.destinations, preselect: model.captureRequest.device)
            model.captureRequest.device = nil
            controller = made
            model.endCapture = { [weak made] in made?.end() }
        }
        // Asked again while open (#316): preselect it if the capture hasn't started; either way it's used up.
        .onChange(of: model.captureRequest.device) { _, device in
            guard let device else { return }
            controller?.refresh(sources: model.sources, destinations: model.destinations, preselect: device)
            model.captureRequest.device = nil
        }
        .onDisappear {
            controller?.end()
            model.endCapture = nil
        }
    }
}

struct CaptureView: View {
    @Bindable var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Step.x4) {
            switch controller.flow.phase {
            case .ports: CapturePortsPage(controller: controller)
            case .steps: CaptureStepPage(controller: controller)
            case .done: CaptureDonePage(controller: controller)
            case .leds: CaptureLEDPage(controller: controller)
            }
        }
        .padding(Theme.Step.x6)
        .frame(width: 480, alignment: .topLeading)
        .background(Theme.panel)
    }
}

/// An eyebrow label over a headline, as the setup guide's.
private struct CaptureHeading: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Step.x1) {
            Text(eyebrow).font(Theme.labelFont).foregroundStyle(Theme.caption)
            Text(title).font(Theme.ui(22, .medium)).tracking(-0.8).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct CapturePortsPage: View {
    @Bindable var controller: CaptureController

    var body: some View {
        CaptureHeading(eyebrow: "Help add a controller", title: "Capture your controller")
        Text("DeckBridge listens while you press, move and turn each control, and records what it sends. "
            + (controller.flow.ledTest
                ? "Nothing is sent to your controller unless you choose the LED test at the end, and nothing"
                : "Nothing is sent to your controller, and nothing")
            + " leaves this Mac unless you save or email the file. It takes about five minutes.")
            .font(Theme.ui(13)).foregroundStyle(Theme.caption)
            .fixedSize(horizontal: false, vertical: true)
        Picker("Controller", selection: $controller.picked) {
            ForEach(controller.choices) { Text($0.name).tag(Optional($0)) }
        }
        .font(Theme.ui(13))
        Text("While it captures, DeckBridge stops sending this controller's moves to Syndicate.")
            .font(Theme.ui(12)).foregroundStyle(Theme.caption)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Start") { controller.start() }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(controller.picked == nil)
        }
    }
}

private struct CaptureStepPage: View {
    let controller: CaptureController

    var body: some View {
        let flow = controller.flow
        CaptureHeading(eyebrow: "Step \(flow.stepNumber) of \(flow.stepCount)", title: flow.prompt?.text ?? "")
        if flow.isDisconnected { CaptureDisconnected { controller.endCapture() } }
        CaptureReadout(
            detected: flow.detected, notes: [flow.shiftReadout, flow.layerReadout].compactMap { $0 },
            idleSecondsLeft: controller.idleSecondsLeft
        )
        HStack(spacing: Theme.Step.x2) {
            Button("Redo") { controller.redo() }
                .buttonStyle(PillButtonStyle())
                .disabled(!flow.canRedo)
            Button("Skip") { controller.skip() }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .disabled(!flow.canSkip)
            Spacer()
            Button("Next") { controller.next() }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canNext)
        }
    }
}

/// What the step has detected so far, live.
private struct CaptureReadout: View {
    let detected: [ControlFacts]
    /// How Shift changed the control (#229), and what a layer step found (#217).
    let notes: [String]
    let idleSecondsLeft: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Step.x2) {
            Text("Detected").font(Theme.labelFont).foregroundStyle(Theme.caption)
            if let idleSecondsLeft {
                line(idleSecondsLeft > 0 ? "Listening… Next in \(idleSecondsLeft) s" : "Done listening", color: Theme.caption)
            } else if detected.isEmpty {
                line("Waiting for the control…", color: Theme.caption)
            } else {
                ForEach(Array(detected.enumerated()), id: \.offset) { line($0.element.summary, color: Theme.text) }
                ForEach(notes, id: \.self) { line($0, color: Theme.caption) }
            }
        }
        .padding(Theme.Step.x4)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text).font(Theme.data(13)).foregroundStyle(color)
    }

    private var accessibilityText: String {
        if let idleSecondsLeft { return idleSecondsLeft > 0 ? "Listening, Next in \(idleSecondsLeft) seconds" : "Done listening" }
        if detected.isEmpty { return "Detected: nothing yet" }
        return "Detected: " + detected.map(\.spoken).joined(separator: ", then ") + notes.map { ". \($0)" }.joined()
    }
}

/// The end (#188): what the file holds, an optional note, and the owner's choice to save or email it.
private struct CaptureDonePage: View {
    @Bindable var controller: CaptureController
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let demo = controller.flow.file?.device == DemoCapture.deviceName
        let partial = (controller.flow.file?.steps.count ?? 0) < controller.flow.stepCount
        CaptureHeading(eyebrow: "Help add a controller", title: partial ? "Capture ended early" : "Capture finished")
        Text("Send it to DeckBridge and it can become a supported controller. Nothing has been sent; it leaves this Mac only if you save or email it." + (demo ? "" : " DeckBridge is sending this controller's moves to Syndicate again."))
            .font(Theme.ui(13)).foregroundStyle(Theme.caption)
            .fixedSize(horizontal: false, vertical: true)
        CaptureContents(lines: controller.flow.file?.summary ?? [])
        TextField("Note (optional), such as your firmware version", text: $controller.note, axis: .vertical)
            .lineLimit(1...3)
            .font(Theme.ui(13))
        if controller.canTestLEDs { CaptureLEDOffer(controller: controller) }
        CaptureExportButtons(controller: controller) { dismissWindow(id: CaptureWindow.id) }
        if let note = controller.exportNote {
            Text(note).font(Theme.ui(12)).foregroundStyle(Theme.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The summary, as a card: "What the file holds".
private struct CaptureContents: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Step.x1) {
            Text("What the file holds").font(Theme.labelFont).foregroundStyle(Theme.caption)
                .padding(.bottom, Theme.Step.x1)
            ForEach(lines, id: \.self) { Text($0).font(Theme.ui(12)).foregroundStyle(Theme.text) }
        }
        .padding(Theme.Step.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureExportButtons: View {
    let controller: CaptureController
    let close: () -> Void

    var body: some View {
        HStack(spacing: Theme.Step.x2) {
            Button("Save…") { controller.save() }
                .buttonStyle(PillButtonStyle())
            Button("Email to DeckBridge") { controller.email() }
                .buttonStyle(PillButtonStyle())
            Spacer()
            Button("Close") { close() }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// The controller went away mid-capture (#229): what to do, and a way out.
private struct CaptureDisconnected: View {
    let end: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Step.x3) {
            Text("Controller disconnected. Plug it back in to continue, or end the capture.")
                .font(Theme.ui(13)).foregroundStyle(Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("End capture", action: end).buttonStyle(PillButtonStyle(small: true))
        }
        .padding(Theme.Step.x3)
        .card()
    }
}

/// The done page's offer of the LED test (#187): Quick or Full, then Test LEDs.
private struct CaptureLEDOffer: View {
    @Bindable var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Step.x2) {
            Text("LED test").font(Theme.labelFont).foregroundStyle(Theme.caption)
            Text("Optional: DeckBridge lights each button and pad in turn and asks what you see, so your controller's lights can work too. It turns everything off again.")
                .font(Theme.ui(12)).foregroundStyle(Theme.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Step.x2) {
                SegmentedPills(options: [LEDProbe.Scope.quick, .full], title: { $0 == .quick ? "Quick" : "Full" }, selection: $controller.ledScope)
                Spacer()
                Button("Test LEDs") { controller.startLEDs() }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(Theme.Step.x4)
        .card()
    }
}

/// One LED probe (#187): the question, and its answers as pills.
private struct CaptureLEDPage: View {
    let controller: CaptureController

    var body: some View {
        let flow = controller.flow
        CaptureHeading(eyebrow: "LED test \(flow.ledProbeNumber) of \(flow.ledProbeCount)", title: flow.ledProbe?.text ?? "")
        CaptureLEDChoices(
            question: flow.ledProbe?.question ?? .lit, enabled: flow.canAnswerLED, sameAsLast: flow.canSameAsLast
        ) { controller.answerLED($0) }
        HStack {
            Spacer()
            Button("Skip LED test") { controller.skipLEDs() }.buttonStyle(PillButtonStyle(kind: .quiet))
        }
    }
}

private struct CaptureLEDChoices: View {
    let question: LEDProbe.Question
    /// Off until the probe has lit on the controller.
    let enabled: Bool
    let sameAsLast: Bool
    let answer: (CaptureFlow.LEDChoice) -> Void

    var body: some View {
        switch question {
        case .lit:
            pills([("Yes, it lit", .lit(true)), ("No", .lit(false))])
        case .level:
            pills([("Dim", .level(.dim)), ("Bright", .level(.bright)), ("Off", .level(nil))])
        case .color:
            VStack(alignment: .leading, spacing: Theme.Step.x2) {
                pills(CaptureFlow.ledColors.map { ($0.capitalized, .color($0)) })
                pills([("Off", .color(nil)), ("Same as last", .sameAsLast)])
            }
        }
    }

    private func pills(_ choices: [(String, CaptureFlow.LEDChoice)]) -> some View {
        FlowRow(spacing: Theme.Step.x2) {
            ForEach(choices, id: \.0) { choice in
                Button(choice.0) { answer(choice.1) }
                    .buttonStyle(PillButtonStyle(small: true))
                    .disabled(!enabled || (choice.1 == .sameAsLast && !sameAsLast))
            }
        }
    }
}

/// Lays its children out left to right, wrapping to a new line when the width runs out.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
