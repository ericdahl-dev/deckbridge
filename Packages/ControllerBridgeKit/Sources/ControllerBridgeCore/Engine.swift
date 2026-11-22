/// The one consumer of an EventPipe: it feeds each event to the Coordinator, in order, on one task.
///
/// No Task per message. The app runs `run(_:)` once, on whatever single executor owns the Coordinator.
public struct Engine {
    private let coordinator: Coordinator
    private let log: any LogSink
    private let onDiagnostic: (@Sendable (DiagnosticEvent) -> Void)?
    /// Makes the demo (#64) when it's turned on; nil, and the demo event does nothing.
    private let makeDemo: (@Sendable (ControllerProfile) -> DemoSession)?
    private let onStatus: (@Sendable (CoordinatorStatus) -> Void)?

    /// `onStatus` gets the Coordinator's status when the loop starts and again each time it changes, on the loop's
    /// task. The app hops it to the main actor once per change.
    public init(
        coordinator: Coordinator, log: any LogSink, onStatus: (@Sendable (CoordinatorStatus) -> Void)? = nil,
        onDiagnostic: (@Sendable (DiagnosticEvent) -> Void)? = nil,
        makeDemo: (@Sendable (ControllerProfile) -> DemoSession)? = nil
    ) {
        self.makeDemo = makeDemo
        self.coordinator = coordinator
        self.log = log
        self.onStatus = onStatus
        self.onDiagnostic = onDiagnostic
    }

    /// Returns when the pipe finishes, or right after a stop.
    public func run(_ events: AsyncStream<PipeEvent>) async {
        // The demo (#64) swaps in its own Coordinator; the real one is stopped meanwhile.
        var demo: DemoSession?
        var diagnosticsOpen = false
        // Settings changes made during the demo wait for the real controller.
        var waitingCommands: [Coordinator.Command] = []
        var active: Coordinator { demo?.coordinator ?? coordinator }
        var status: CoordinatorStatus { demo?.status ?? coordinator.status }

        func setDiagnostics(_ target: Coordinator, open: Bool) {
            if open, let sink = onDiagnostic { target.diagnostics = { sink($0) } } else { target.diagnostics = nil }
        }

        var reported = status
        onStatus?(reported)
        for await event in events {
            defer {
                if status != reported {
                    reported = status
                    onStatus?(reported)
                }
            }
            switch event {
            case .midi(let midi, let source):
                // The real controller is stopped during the demo.
                if demo == nil { coordinator.midi(midi, source: source) }
            case .udp(let datagram):
                guard demo == nil else { continue }
                do {
                    for message in try OSCPacket(decoding: datagram).messages { coordinator.feedback(message) }
                } catch {
                    log.log("Dropped a feedback datagram (\(datagram.count) bytes): \(error)")
                }
            case .tick:
                if let demo { demo.tick() } else { coordinator.tick() }
            case .devicesChanged(let removed):
                // The real controller re-reads the devices when the demo ends.
                if demo == nil { coordinator.devicesChanged(removed: removed) }
            case .sleep: active.willSleep()
            case .wake: if demo == nil { coordinator.didWake() }
            // Only while the window is open does the Coordinator build anything for it.
            case .diagnostics(let open):
                diagnosticsOpen = open
                setDiagnostics(active, open: open)
            // The real unit's display answers the real Coordinator, demo or not.
            case .jogDisplayReply(let bytes): coordinator.jogDisplayReply(bytes)
            // Every command goes where its routing says (#386); the Engine never names one.
            case .command(let command):
                switch command.routing {
                case .waitsForDemo: if demo == nil { coordinator.apply(command) } else { waitingCommands.append(command) }
                case .real: coordinator.apply(command)
                case .active: active.apply(command)
                case .realAndDemo:
                    coordinator.apply(command)
                    demo?.coordinator.apply(command)
                }
            case .demo(let on):
                if on, demo == nil, let makeDemo {
                    // The profile running now, so an imported mapping shows in the demo too (#98).
                    let session = makeDemo(coordinator.runningProfile)
                    // The deck panel follows the demo, as the preview does (#625): handed over before the real
                    // controller stops, so its stopping puts nothing on the panel.
                    session.coordinator.takeDisplayFeed(from: coordinator)
                    coordinator.stop()
                    setDiagnostics(coordinator, open: false)
                    setDiagnostics(session.coordinator, open: diagnosticsOpen)
                    session.start()
                    demo = session
                } else if !on, let session = demo {
                    session.stop()
                    demo = nil
                    for command in waitingCommands { coordinator.apply(command) }
                    waitingCommands.removeAll()
                    setDiagnostics(coordinator, open: diagnosticsOpen)
                    coordinator.start()
                    // Back to the real deck in front, with a full snapshot, under the setting as it is now (#625).
                    coordinator.takeBackDisplayFeed(from: session.coordinator)
                }
            case .stop:
                // Releases are sent synchronously, so they have all gone out once run() returns. Quit, not stop: a
                // drawing jog display keeps our logo (#600).
                // The demo's Coordinator holds the display feed while it runs: it says the goodbye (#651).
                demo?.coordinator.displayFeedGoodbye()
                demo?.stop()
                coordinator.quit()
                return
            }
        }
    }
}
