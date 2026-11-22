// Drives the capture window (#186): the Kit's CaptureFlow, fed by the capture MIDI input or the demo controller.
// Not unit-tested: every rule lives in CaptureFlow (Kit), and the live path is on the manual checklist.
import ControllerBridgeCapture
import ControllerBridgeCore
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class CaptureController {
    /// A port the owner can pick: a real source, or the demo controller.
    struct Choice: Hashable, Identifiable {
        var name: String
        var endpoint: MIDIEndpoint?
        /// By endpoint, so two units of the same name stay apart.
        var id: String { endpoint.map { "\($0.id)" } ?? "demo" }
    }

    private(set) var flow = CaptureFlow(appVersion: CaptureController.appVersion, ledTest: CaptureController.ledTestEnabled)

    /// The LED test (#187) stays off until it has been checked at a real unit. For that check:
    /// `defaults write dev.ericdahl.ControllerBridge CaptureLEDTest -bool YES`.
    static var ledTestEnabled: Bool { UserDefaults.standard.bool(forKey: "CaptureLEDTest") }
    /// The host time, refreshed every second for the idle countdown.
    private(set) var now = ProcessInfo.processInfo.systemUptime
    var picked: Choice?
    private(set) var choices: [Choice] = []

    private var input: CaptureMIDIInput?
    private var listenTask: Task<Void, Never>?
    /// When the bridge pauses the controller and gets it back: the Kit's rules (#326).
    private var hold = CaptureHold(source: nil)
    /// The picked source, watched for an unplug mid-capture (#229).
    private var watched: MIDIEndpoint?
    private var watch: CaptureWatch?
    private var demoTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private let setCapture: (MIDIEndpoint.ID?) -> Void
    private var destinations: [MIDIEndpoint] = []
    /// The controller's main output, for the LED test (#187).
    private var ledDestination: MIDIEndpoint?
    private var ledOutput: CaptureMIDIOutput?
    private var sendTask: Task<Void, Never>?
    /// Quick (transport and pads) or Full, chosen on the done page.
    var ledScope: LEDProbe.Scope = .full

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    /// `setCapture` pauses (a source) or gives back (nil) a controller in the bridge.
    init(setCapture: @escaping (MIDIEndpoint.ID?) -> Void) {
        self.setCapture = setCapture
    }

    #if DEBUG
    /// Snapshots only: a flow already in some state, at a fixed time.
    init(flow: CaptureFlow, now: Double, choices: [Choice] = [], picked: Choice? = nil) {
        self.flow = flow
        self.now = now
        self.choices = choices
        self.picked = picked
        setCapture = { _ in }
    }
    #endif

    /// Lists the ports, with the demo controller last. Called when the window opens.
    func refresh(sources: [MIDIEndpoint], destinations: [MIDIEndpoint], preselect: String? = nil) {
        guard flow.phase == .ports else { return }
        self.destinations = destinations
        choices = sources.map { Choice(name: $0.name, endpoint: $0) } + [Choice(name: DemoCapture.deviceName, endpoint: nil)]
        if let preselect, let match = choices.first(where: { $0.name == preselect }) { picked = match }
        if picked.map(choices.contains) != true { picked = choices.first }
    }

    func start() {
        guard let picked else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if let endpoint = picked.endpoint {
            let others = choices.compactMap(\.endpoint).filter { $0.id != endpoint.id }
            let ports = CapturePorts.suggested(for: picked.name, sources: others.map(\.name), destinations: destinations.map(\.name))
            // The picked endpoint itself, then the device's other ports (the first of each name).
            let listened = [endpoint] + ports.input.dropFirst().compactMap { name in others.first { $0.name == name } }
            watched = endpoint
            watch = CaptureWatch(source: endpoint.id)
            hold = CaptureHold(source: endpoint.id)
            apply(hold.stepsStarted())
            listen(to: listened)
            // The output on the same device entity; by name only when exactly one destination has it.
            ledDestination = CaptureMIDIOutput.destination(pairedWith: endpoint) ?? ports.output.first.flatMap { name in
                let named = destinations.filter { $0.name == name }
                return named.count == 1 ? named[0] : nil
            }
            flow.start(device: picked.name, ports: ports, at: time)
        } else {
            flow.start(device: DemoCapture.deviceName, ports: DemoCapture.ports, at: time)
        }
        startClock()
        stepChanged()
    }

    func next() { act { flow.next(at: $0) } }
    /// Ends the capture now, keeping the steps so far (#229).
    func endCapture() { act { flow.endCapture(at: $0) } }
    func redo() { act { flow.redo(at: $0) } }
    func skip() { act { flow.skip(at: $0) } }

    var canNext: Bool { flow.canNext(at: now) }
    var idleSecondsLeft: Int? { flow.idleSecondsLeft(at: now) }

    /// One stream, read by one task, so messages reach the flow in the order they came (a 14-bit pair needs its MSB
    /// before its LSB).
    private func listen(to sources: [MIDIEndpoint]) {
        let (stream, continuation) = AsyncStream<([UInt8], Double, Int)>.makeStream()
        input = CaptureMIDIInput(
            sources: sources,
            receive: { bytes, time, port in continuation.yield((bytes, time, port)) },
            changed: { [weak self] in Task { @MainActor in self?.devicesChanged() } }
        )
        listenTask = Task { [weak self] in
            for await (bytes, time, port) in stream { self?.receive(bytes, at: time, port: port) }
        }
    }

    // MARK: The LED test (#187)

    /// Whether the done page offers the LED test: once, and only with a way to reach the controller (the demo has none
    /// to reach, and needs none).
    var canTestLEDs: Bool { flow.canStartLEDs && (isDemo || ledDestination != nil) }

    private var isDemo: Bool { flow.file?.device == DemoCapture.deviceName }

    /// Starts the LED test: opens the controller's main output (the demo controller has none: its sends go nowhere)
    /// and lets ProbeSender's messages out every 50 ms.
    func startLEDs() {
        guard canTestLEDs else { return }
        if !isDemo {
            if ledOutput == nil, let ledDestination { ledOutput = CaptureMIDIOutput(destination: ledDestination) }
            guard ledOutput != nil else {
                exportNote = "DeckBridge can't reach the controller's output, so the LED test can't run."
                return
            }
            // The bridge holds the controller again, LEDs included, so the test isn't painted over (#187).
            apply(hold.ledTestStarted())
        }
        flow.startLEDs(scope: ledScope, at: ProcessInfo.processInfo.systemUptime)
        announce()
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.sendDue()
            }
        }
    }

    func answerLED(_ choice: CaptureFlow.LEDChoice) {
        flow.answerLED(choice, at: ProcessInfo.processInfo.systemUptime)
        announce()
    }

    func skipLEDs() {
        flow.skipLEDs(at: ProcessInfo.processInfo.systemUptime)
        announce()
    }

    private func sendDue() {
        for message in flow.dueSends(at: ProcessInfo.processInfo.systemUptime) { ledOutput?.send(message) }
        // The test is over and everything is off: give the controller back, which repaints its LEDs.
        apply(hold.sendsDrained(phase: flow.phase, pending: flow.hasPendingSends))
    }

    /// Before the output closes: ends the LED test, and sends what's still queued (its off messages), keeping the gap,
    /// without blocking the main thread (#326).
    private func flushLEDs() async {
        flow.skipLEDs(at: ProcessInfo.processInfo.systemUptime)
        var left = 64
        while flow.hasPendingSends, left > 0 {
            sendDue()
            if flow.hasPendingSends { try? await Task.sleep(for: .seconds(ProbeSender.interval)) }
            left -= 1
        }
    }

    /// The steps are done: nothing more is heard, and the bridge gets the controller back until an LED test (#187).
    private func endListening() {
        input?.stop()
        input = nil
        listenTask?.cancel()
        demoTask?.cancel()
        apply(hold.stepsDone())
    }

    /// Ends the capture: the LED test turns off what it lit, the bridge gets the controller back, and nothing more is
    /// heard. Safe to call twice.
    func end() {
        sendTask?.cancel()
        sendTask = nil
        input?.stop()
        input = nil
        listenTask?.cancel()
        demoTask?.cancel()
        clockTask?.cancel()
        // With an LED output open, its lights go off first (a few messages, 100 ms apart), then it closes and the
        // controller goes back; the flush runs on, without holding up the window or the main thread (#326).
        guard let output = ledOutput else { return apply(hold.end()) }
        ledOutput = nil
        Task { [weak self] in
            guard let self else { return output.close() }
            self.ledOutput = output
            await self.flushLEDs()
            output.close()
            self.ledOutput = nil
            self.apply(self.hold.end())
        }
    }

    /// Pauses or gives back the controller, as CaptureHold says.
    private func apply(_ action: CaptureHold.Action?) {
        switch action {
        case .pause(let source): setCapture(source)
        case .giveBack: setCapture(nil)
        case nil: break
        }
    }

    private func act(_ change: (Double) -> Void) {
        let time = ProcessInfo.processInfo.systemUptime
        now = time
        change(time)
        stepChanged()
        if flow.phase == .done { endListening() }
    }

    private func receive(_ bytes: [UInt8], at time: Double, port: Int) {
        flow.receive(bytes, at: time, port: port)
        announce()
    }

    /// A new step or a redo: announce it, and play the demo controller's answer if it's the one being captured.
    private func stepChanged() {
        announce()
        guard flow.file?.device == DemoCapture.deviceName, let prompt = flow.prompt else { return }
        demoTask?.cancel()
        demoTask = Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime + 1
            for message in DemoCapture.take(for: prompt) {
                let at = start + message.time
                try? await Task.sleep(for: .seconds(max(0, at - ProcessInfo.processInfo.systemUptime)))
                guard !Task.isCancelled else { return }
                self?.receive(message.bytes, at: at, port: 0)
            }
        }
    }

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    // MARK: Done (#188): nothing leaves the Mac without one of these clicks

    /// The owner's note, bound to the done page's field.
    var note: String {
        get { flow.note }
        set { flow.note = newValue }
    }

    /// Shown under the buttons after Save… or Email, or when email can't be opened.
    private(set) var exportNote: String?

    static let fileType = UTType(exportedAs: "dev.ericdahl.deckbridge.capture", conformingTo: .json)

    /// Saves the file through the save panel: the owner picks the place, so the sandbox allows it.
    func save() {
        guard let file = flow.file, let data = try? file.encoded() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.suggestedFileName
        panel.allowedContentTypes = [Self.fileType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            exportNote = "Saved \(url.lastPathComponent)."
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Opens a new message in the owner's own mail app, to DeckBridge, with the file attached. Sending it is theirs.
    func email() {
        guard let file = flow.file, let data = try? file.encoded() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.suggestedFileName)
        guard (try? data.write(to: url, options: .atomic)) != nil,
            let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [url])
        else {
            exportNote = "No mail app is set up. Save the file and attach it to an email to \(CaptureFile.emailRecipient)."
            return
        }
        service.recipients = [CaptureFile.emailRecipient]
        service.subject = file.emailSubject
        service.perform(withItems: [file.emailBody, url])
        exportNote = "Your mail app has the message ready. It's sent only when you send it."
    }

    /// The picked controller went away or came back (#229). Back, it's listened to again, and the bridge pauses it
    /// again: an unplug had ended that pause.
    private func devicesChanged() {
        guard watched != nil, flow.phase == .steps else { return }
        let time = ProcessInfo.processInfo.systemUptime
        switch watch?.sourcesChanged(online: CaptureMIDIInput.onlineSourceIDs()) {
        case .disconnected:
            flow.disconnected(at: time)
        case .reconnected:
            input?.connect()
            apply(hold.reconnected())
            flow.reconnected(at: time)
        case nil:
            break
        }
        announce()
    }

    private func tick() {
        now = ProcessInfo.processInfo.systemUptime
        flow.tick(at: now)
        announce()
    }

    private func announce() {
        guard let text = flow.takeAnnouncement() else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}
