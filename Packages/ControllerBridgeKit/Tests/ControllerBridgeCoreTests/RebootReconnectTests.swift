import Foundation
@testable import ControllerBridgeCore
import Testing

/// A quick power cycle of the unit (#429): its endpoints are removed and back, with the same ids, before the device
/// change is handled. The unit comes back in standalone state (LEDs cleared, the display not in host mode), so a
/// controller removed and back is reconnected as if unplugged and plugged in again.
@Suite("Reboot reconnect")
struct RebootReconnectTests {
    /// Every note the LC6000's LED output was sent, across reopened outputs.
    static func ledNotes(_ rig: Rig) -> Set<UInt8> {
        Set((rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).compactMap { if case .noteOn(_, let note, _) = $0 { note } else { nil } })
    }

    @Test("Removed and back in one device change: a held Cue is released once, and every LED is painted again")
    func removedAndBackReconnects() throws {
        let rig = try Rig()
        rig.coordinator.start()
        let painted = Self.ledNotes(rig)
        rig.coordinator.midi(.noteOn(channel: 0, note: 2, velocity: 127), source: Rig.lc6000.id)   // Cue held
        rig.osc.sent.removeAll()
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        rig.coordinator.devicesChanged(removed: [Rig.lc6000.id])
        #expect(rig.osc.sent.filter { $0.address.hasSuffix("/Cue") } == [OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)])])
        #expect(Self.ledNotes(rig).isSuperset(of: painted))
        #expect(rig.coordinator.status.controllers.first?.connected == true)
    }

    @Test("The display's WD port removed and back: goodbye, then hello and fresh uploads; the LEDs repainted after, the ring at 0")
    func displayReconnects() throws {
        let (rig, port) = try JogDisplayRingHoldTests.owned()
        rig.coordinator.setJogDisplay(enabled: true)
        for _ in 0..<4 { JogDisplayRingHoldTests.answer(rig, port) }
        port.controller.removeAll()
        port.wd.removeAll()
        let out = try #require(rig.midi.outputs[JogDisplayRingHoldTests.lc6000.id + 1000])
        let painted = Set(out.sent.compactMap { if case .noteOn(_, let note, _) = $0 { note } else { nil } })
        out.sent.removeAll()
        rig.coordinator.devicesChanged(removed: [JogDisplayRingHoldTests.wd.id])
        #expect(port.controller.first == JogDisplay.goodbye)
        #expect(port.controller.contains(JogDisplay.hello.last ?? []))
        #expect(port.wd.contains { $0.count > 6 && $0[6] == 0x0C })   // an upload started
        let after = rig.midi.outputs[JogDisplayRingHoldTests.lc6000.id + 1000]?.sent ?? []
        #expect(Set(after.compactMap { if case .noteOn(_, let note, _) = $0 { note } else { nil } }).isSuperset(of: painted))
        #expect(after.last { if case .noteOn(_, 40, _) = $0 { true } else { false } } == .noteOn(channel: 0, note: 40, velocity: 0))
    }

    @Test("Following layers on layer 3, then removed and back: the unit's next layer signal (layer 2) makes layer 2 active")
    func layerRelearned() throws {
        let rig = try LayersTests.layered()
        LayersTests.switchLayer(rig, from: 1, to: 3)
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, false, true, false])
        rig.coordinator.devicesChanged(removed: [Rig.lc6000.id])
        LayersTests.note(rig, channel: 2, 51, 127)   // the unit came back on layer 2 (power-on deck select)
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, true, false, false])
    }

    @Test("A device change that removed nothing: no LEDs sent again and no hello, as before #429")
    func nothingRemoved() throws {
        let (rig, port) = try JogDisplayRingHoldTests.owned()
        rig.coordinator.setJogDisplay(enabled: true)
        for _ in 0..<4 { JogDisplayRingHoldTests.answer(rig, port) }
        port.controller.removeAll()
        let out = try #require(rig.midi.outputs[JogDisplayRingHoldTests.lc6000.id + 1000])
        out.sent.removeAll()
        rig.coordinator.devicesChanged()
        #expect(port.controller.isEmpty)
        #expect(out.sent.isEmpty)
    }
}
