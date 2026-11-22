@testable import ControllerBridgeCore
import Testing

/// Censor shows reverse, and the deck select button flashes (#477).
@Suite("Censor and deck select lights")
struct CensorDeckSelectLightsTests {
    typealias Press = PressLitButtonsTests

    @Test("Censor (7) is full while held, and idle (1) again on release")
    func censorHeld() throws {
        let rig = try Press.started()
        #expect(rig.leds[7] == 1)
        Press.note(rig, 7, down: true)
        #expect(rig.leds[7] == 127)
        Press.note(rig, 7, down: false)
        #expect(rig.leds[7] == 1)
    }

    @Test("Shift + Censor latches reverse: Censor stays full after release, until the next Shift + Censor")
    func censorLatched() throws {
        let rig = try Press.started()
        Press.note(rig, 26, down: true)
        Press.note(rig, 7, down: true)
        Press.note(rig, 7, down: false)
        Press.note(rig, 26, down: false)
        #expect(rig.leds[7] == 127)
        Press.note(rig, 26, down: true)
        Press.note(rig, 7, down: true)
        Press.note(rig, 7, down: false)
        Press.note(rig, 26, down: false)
        #expect(rig.leds[7] == 1)
    }

    @Test("Release-all (here the Mac going to sleep) turns a latched reverse off, and Censor's light with it")
    func censorReleaseAll() throws {
        let rig = try Press.started()
        Press.note(rig, 26, down: true)
        Press.note(rig, 7, down: true)
        Press.note(rig, 7, down: false)
        Press.note(rig, 26, down: false)
        rig.coordinator.willSleep()
        #expect(rig.leds[7] == 1)
    }

    @Test("Release-all with Censor still held turns its light back to idle too")
    func censorHeldReleaseAll() throws {
        let rig = try Press.started()
        Press.note(rig, 7, down: true)
        rig.coordinator.willSleep()
        #expect(rig.leds[7] == 1)
    }

    @Test("Deck select (23), with no layers: idle dim, full while pressed")
    func deckSelectAlone() throws {
        let rig = try Press.started()
        #expect(rig.leds[23] == 1)
        Press.note(rig, 23, down: true)
        #expect(rig.leds[23] == 127)
        Press.note(rig, 23, down: false)
        #expect(rig.leds[23] == 1)
    }

    /// The LC6000 with its deck layers: deck select steps to the next layer (#420).
    static func layered() throws -> Rig {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: LayersTests.lc6000Layers))
        return rig
    }

    @Test("Deck select with layers: full on press on the layer it steps to, idle on release, round every layer and back")
    func deckSelectLayers() throws {
        let rig = try Self.layered()
        #expect(rig.leds[23] == 1)
        for step in 0..<(LayersTests.lc6000Layers.count + 1) {
            rig.clock.now = Double(step)   // a second apart: each a lone step (#553)
            Press.note(rig, 23, down: true)
            #expect(rig.leds[23] == 127, "step \(step) pressed")
            Press.note(rig, 23, down: false)
            #expect(rig.leds[23] == 1, "step \(step) released")
        }
    }

    /// Every light from #476 and #477: the dark buttons, Censor and deck select.
    static let topPanel: Set<UInt8> = Set(Press.notes + [7, 23])

    static func noteOns(_ sent: [MIDIEvent]) -> [(note: UInt8, velocity: UInt8)] {
        sent.compactMap { if case .noteOn(_, let note, let velocity) = $0 { (note, velocity) } else { nil } }
    }

    @Test("A reconnect (#429) sends every top panel light again")
    func reconnect() throws {
        let rig = try Press.started()
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        rig.coordinator.devicesChanged(removed: [Rig.lc6000.id])
        let sent = Set(Self.noteOns(rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).map(\.note))
        #expect(Self.topPanel.isSubset(of: sent))
    }

    @Test("The jog display's hello (#426) sends every top panel light again")
    func hello() throws {
        let (rig, _) = try JogDisplayRingHoldTests.owned()
        let before = JogDisplayHelloRepaintTests.sent(rig).count
        rig.coordinator.setJogDisplay(enabled: true)
        let after = Set(JogDisplayHelloRepaintTests.sent(rig).dropFirst(before).map(\.note))
        #expect(Self.topPanel.isSubset(of: after))
    }

    @Test("Censor latched on layer 1, then deck select to layer 2: leaving ends the latch, and Censor is never full after")
    func hiddenLayer() throws {
        let rig = try Self.layered()
        Press.note(rig, 26, down: true)
        Press.note(rig, 7, down: true)
        Press.note(rig, 7, down: false)
        Press.note(rig, 26, down: false)
        #expect(rig.leds[7] == 127)
        rig.midi.outputs[Rig.lc6000Out.id]?.sent.removeAll()
        Press.note(rig, 23, down: true)
        Press.note(rig, 23, down: false)
        let censor = Self.noteOns(rig.midi.outputs[Rig.lc6000Out.id]?.sent ?? []).filter { $0.note == 7 }.map(\.velocity)
        #expect(!censor.contains(127) && censor.last == 1)
    }
}
