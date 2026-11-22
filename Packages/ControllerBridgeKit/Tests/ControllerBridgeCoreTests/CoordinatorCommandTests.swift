import Foundation
@testable import ControllerBridgeCore
import Testing

/// Coordinator.Command (#386): every change the app asks of the Coordinator is one value, applied in one place, and
/// says itself where it goes while the demo runs. A new command is a case here and a call in BridgeModel; the pipe and
/// the Engine don't name it.
@Suite("Coordinator commands")
struct CoordinatorCommandTests {
    static func started() throws -> Rig {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        return rig
    }

    @Test("apply runs the command: setDeck moves the controller to deck 3; resync asks Syndicate to resend")
    func applies() throws {
        let rig = try Self.started()
        rig.coordinator.apply(.setDeck(3, controller: 0))
        #expect(rig.coordinator.status.controllers.first?.deck == 3)
        rig.coordinator.apply(.resync)
        #expect(rig.osc.sent.contains(OSCMessage("/Syndicate/Feedback/Resend", [.int(1)])))
    }

    @Test("Where each command goes while the demo runs: settings wait for the real controller; the rest go straight through")
    func routing() {
        #expect(Coordinator.Command.setDeck(1, controller: 0).routing == .waitsForDemo)
        #expect(Coordinator.Command.setLEDs(enabled: true).routing == .waitsForDemo)
        #expect(Coordinator.Command.setDevices(input: nil, output: nil, controller: 0).routing == .waitsForDemo)
        #expect(Coordinator.Command.setDeckColors(followSyndicate: true, custom: .defaults).routing == .waitsForDemo)
        #expect(Coordinator.Command.setRingColors(.vivid).routing == .waitsForDemo)
        #expect(Coordinator.Command.setColorMessages(true).routing == .waitsForDemo)
        #expect(Coordinator.Command.setLightBrightness(50).routing == .waitsForDemo)
        #expect(Coordinator.Command.resync.routing == .waitsForDemo)
        #expect(Coordinator.Command.setControllers([]).routing == .waitsForDemo)
        #expect(Coordinator.Command.setProfiles([]).routing == .waitsForDemo)
        #expect(Coordinator.Command.setProfileChoices([:]).routing == .waitsForDemo)
        #expect(Coordinator.Command.setJogDisplay(enabled: true).routing == .waitsForDemo)
        // A real device is captured, so the real Coordinator pauses it, demo or not.
        #expect(Coordinator.Command.setCapture(source: nil).routing == .real)
        #expect(Coordinator.Command.startMeterCapture(seconds: 10).routing == .real)
        // The sweep runs on whichever Coordinator is active.
        #expect(Coordinator.Command.ledSweep(delay: 0.5).routing == .active)
        #expect(Coordinator.Command.stopLEDSweep.routing == .active)
        // The preview's deck holds for the real controller and the demo alike.
        #expect(Coordinator.Command.setJogPreviewDeck(2).routing == .realAndDemo)
    }
}
