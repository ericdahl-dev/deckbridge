// Wires the adapters to the Kit. Not unit-tested: the Engine and Coordinator are tested in ControllerBridgeKit, the rest by
// the smoke script.
import Dispatch
import Foundation
import ControllerBridgeCore
import ControllerBridgeRender
import os

/// Makes the Coordinator inside one task and runs the Engine loop there, so that loop is the only code that ever
/// touches it. Anything else that must reach the Coordinator (stop, sleep, device changes) goes through the pipe,
/// which also keeps it in order with the MIDI already queued.
enum BridgeHost {
    static func run(
        profiles: [ControllerProfile], midi: any MIDISystem, osc: any OSCSender, log: any LogSink, status: BridgeStatus,
        diagnostics: DiagnosticsLog, jogSimulator: JogSimulatorLog, controllers: [ControllerSettings], ledsEnabled: Bool, jogDisplay: (any JogDisplayPort)?,
        displayFeed: (any OSCSender)? = nil, cableFeed: (any OSCSender)? = nil, events: AsyncStream<PipeEvent>
    ) async {
        let coordinator = Coordinator(profiles: profiles, midi: midi, osc: osc, clock: SystemClock(), log: log)
        #if DEBUG
        // Everything an agent needs, to os_log and Library/Logs/DeckBridge (#395). Set before start, so ports trace too.
        coordinator.trace = DebugTrace.shared.sink
        // The meter capture (#582): its CSV goes next to the trace, in Library/Logs/DeckBridge.
        coordinator.meterCaptureSink = { csv in DebugTrace.shared.writeCapture(csv, named: "meter-capture") }
        #endif
        // The LC6000's jog display (#165). Off until Settings turns it on, which comes through the pipe. Always attached:
        // with no WD port, or with the switch off, it only previews, for the Diagnostics simulator (#221).
        let jogEvents = jogSink(jogSimulator)
        // Beat mode (#215): each deck's content goes up once per lit master beat, into that deck's own slots, and each
        // beat shows the front deck's slot. Every deck stays on the unit, so a deck switch uploads nothing (#424).
        let driver = JogDisplayDriver(port: jogDisplay, clock: SystemClock(), log: log, renderBeat: { content, beat in
            JogDisplayRenderer.uploadImage(content, litBeat: beat)
        }) { content in
            JogDisplayRenderer.uploadImage(content)
        }
        #if DEBUG
        driver.trace = DebugTrace.shared.sink
        let trace = DebugTrace.shared.sink
        driver.onEvent = { event in
            // Not the preview's per-tick events (#605): they filled the trace file in about a minute.
            if let line = event.traceLine { trace(.jogDisplay, line) }
            jogEvents(event)
        }
        #else
        driver.onEvent = jogEvents
        #endif
        coordinator.attachJogDisplay(driver)
        // The display feed (#616): off until Settings turns it on, which comes through the pipe.
        if let displayFeed { coordinator.attachDisplayFeed(displayFeed) }
        // The same feed over the USB cable (#667): off until its own switch turns it on.
        if let cableFeed { coordinator.attachCableFeed(cableFeed) }
        // Straight onto the saved devices, decks, layers and LEDs switch: nothing unchosen, even for a moment (#105).
        coordinator.start(controllers: controllers, ledsEnabled: ledsEnabled)
        // The demo controller (#64) runs the profile running now (an imported mapping too, #98) against an in-process
        // controller and an in-memory Syndicate.
        let makeDemo: @Sendable (ControllerProfile) -> DemoSession = { profile in
            let session = DemoSession(profile: profile, clock: SystemClock(), log: log, ledOutput: DroppedMIDIOutput())
            // The demo's deck shows in the jog display preview too (#221); it has no unit, so it only previews.
            let preview = JogDisplayDriver(port: nil, clock: SystemClock(), log: log) { content in JogDisplayRenderer.uploadImage(content) }
            preview.onEvent = jogEvents
            session.coordinator.attachJogDisplay(preview)
            return session
        }
        await Engine(
            coordinator: coordinator, log: log, onStatus: statusSink(status), onDiagnostic: diagnosticsSink(diagnostics),
            makeDemo: makeDemo
        ).run(events)
    }

    /// Hands each Diagnostics line to the window, one main-actor hop per line. Only called while the window is open.
    private nonisolated static func diagnosticsSink(_ log: DiagnosticsLog) -> @Sendable (DiagnosticEvent) -> Void {
        { event in Task { @MainActor in log.append(event) } }
    }

    /// Hands each jog display event to the simulator's feed (#221), which hops to the window only while Diagnostics is
    /// open (#318).
    private nonisolated static func jogSink(_ simulator: JogSimulatorLog) -> @Sendable (JogDisplayEvent) -> Void {
        let feed = simulator.feed
        return { event in feed.receive(event, at: .now) }
    }

    /// Copies each Coordinator status change into the menu's status, with one main-actor hop per change. Made here,
    /// outside any actor: a closure written in main-actor code and called on the engine's task traps (#14 spike).
    private nonisolated static func statusSink(_ status: BridgeStatus) -> @Sendable (CoordinatorStatus) -> Void {
        { coordinatorStatus in
            #if DEBUG
            DebugTrace.shared.status(coordinatorStatus)
            #endif
            Task { @MainActor in
                status.bridges = coordinatorStatus.controllers
                status.devices = coordinatorStatus.devices
                // Stamp the time a dropout happens, for the panel's LAST DROPOUT (#66).
                if coordinatorStatus.feedback == .stale, status.syndicateFeedback != .stale {
                    status.lastDropoutTime = Date.now.formatted(date: .omitted, time: .shortened)
                }
                status.syndicateFeedback = coordinatorStatus.feedback
                status.noDeckData = coordinatorStatus.noDeckData
                status.missingSubscriptions = coordinatorStatus.missingSubscriptions
                status.otherHost = coordinatorStatus.otherHost
                status.displayFound = coordinatorStatus.displayFound
                status.requiredSubscriptions = coordinatorStatus.requiredSubscriptions
                status.lastDropout = coordinatorStatus.lastDropout
                status.sweeping = coordinatorStatus.sweeping
                status.demo = coordinatorStatus.demo
                status.deckColors = coordinatorStatus.deckColors
            }
        }
    }
}

/// Puts a tick into the pipe every 10 ms, for the Coordinator's timers (the jog release, #17).
final class Ticker: Sendable {
    private let timer: any DispatchSourceTimer

    init(producer: EventPipe.Producer) {
        timer = Self.makeTimer(producer)
        timer.resume()
    }

    private nonisolated static func makeTimer(_ producer: EventPipe.Producer) -> any DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.ericdahl.ControllerBridge.tick"))
        // A tight leeway (#582): up to 5 ms of it made the needle's steps uneven (they go every other tick, 20 ms). 1 ms
        // still lets the system batch wakeups a little.
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { producer.tick() }
        return timer
    }

    func stop() { timer.cancel() }
}

struct SystemClock: ControllerBridgeCore.Clock {
    var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

/// The Coordinator's log goes to the unified log (and to stdout when run from a terminal, for the smoke script).
struct UnifiedLogSink: LogSink {
    private static let logger = Logger(subsystem: "dev.ericdahl.ControllerBridge", category: "bridge")
    func log(_ line: String) {
        Self.logger.info("\(line, privacy: .public)")
        print(line)
    }
}

/// The demo controller has no LEDs to light (#64): its LED writes go nowhere.
struct DroppedMIDIOutput: MIDIOutput {
    func send(_ event: MIDIEvent) throws {}
    func send(color: LEDColorMessage) throws {}
    func close() {}
}
