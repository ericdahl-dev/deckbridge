import Foundation
@testable import ControllerBridgeCore
import Testing

/// Coordinator.Command through the event pipe (#386): one send for every command, in order with the MIDI around it,
/// routed by the Engine from the command's own routing, never by naming the command.
@Suite("Commands through the pipe")
struct CommandPipeTests {
    @Test("In order with the MIDI around it: a capture (real) pauses the controller; nil gives it back")
    func inOrder() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        let pipe = EventPipe()
        pipe.producer.send(.setCapture(source: Rig.lc6000.id))
        pipe.producer.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.send(.setCapture(source: nil))
        pipe.producer.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/Cue", [.int(1)])])
    }

    @Test("Settings sent during the demo wait, then reach the real controller in order when it ends")
    func waitsForDemo() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        let pipe = EventPipe()
        pipe.producer.demo(on: true)
        pipe.producer.send(.setDeck(2, controller: 0))
        pipe.producer.send(.setDeck(3, controller: 0))
        pipe.producer.demo(on: false)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, makeDemo: EngineTests.demoMaker(rig)).run(pipe.events)
        #expect(rig.coordinator.status.controllers.map(\.deck) == [3])
    }

    @Test("The LED sweep (active) runs on the demo's Coordinator while the demo is on, not the real one")
    func activeGoesToTheDemo() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        let pipe = EventPipe()
        let seen = EngineTests.SeenDiagnostics()
        pipe.producer.demo(on: true)
        pipe.producer.diagnostics(open: true)
        pipe.producer.send(.ledSweep(delay: 0.6))
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, onDiagnostic: { seen.append($0) }, makeDemo: EngineTests.demoMaker(rig))
            .run(pipe.events)
        // Diagnostics follow the active Coordinator, so the sweep's lines come from the demo's; the real one never sweeps.
        #expect(seen.values.first { $0.text.hasPrefix("Color sweep") } != nil)
        #expect(!rig.coordinator.status.sweeping)
    }

    @Test("A capture (real) sent while the demo runs pauses the real controller, not the demo's: after the demo, its Play sends nothing")
    func realDuringDemo() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        let pipe = EventPipe()
        pipe.producer.demo(on: true)
        pipe.producer.send(.setCapture(source: Rig.lc6000.id))
        pipe.producer.demo(on: false)
        pipe.producer.midi(.noteOn(channel: 0, note: 1, velocity: 127), source: Rig.lc6000.id)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, makeDemo: EngineTests.demoMaker(rig)).run(pipe.events)
        #expect(!rig.osc.sent.contains(OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])))
    }
}
