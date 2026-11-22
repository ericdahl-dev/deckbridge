import ControllerBridgeCore
import Foundation
import Testing

/// Following the controller's own deck layers (#79). The LC6000's Shift + deck select (ch16 note 55) steps its layer
/// ch1 → ch2 → ch3 → ch4; note 51 goes out at velocity 0 on the old channel and 127 on the new one, and every control
/// then arrives on the new channel. MIDI channel N drives Syndicate deck N. Literals are from the hardware capture.
@Suite("Controller layers")
struct LayersTests {
    @Test("The LC6000 profile lists its four layers, channel N → deck N, and note 51 as the active-layer signal")
    func lc6000Layers() throws {
        let midi = try Mapping.bundledDefault().midi
        #expect(midi.layers == [
            Mapping.Layer(channel: 1, deck: 1), Mapping.Layer(channel: 2, deck: 2),
            Mapping.Layer(channel: 3, deck: 3), Mapping.Layer(channel: 4, deck: 4),
        ])
        #expect(midi.layerNote == 51)
    }

    @Test("The mapping check guards layers: channel 1-16, deck 1-4, the layer note 0-127, and no channel used twice")
    func layerChecks() {
        #expect(Mapping.problems(in: Data(#"{"midi": {"layers": [{"channel": 17, "deck": 5}], "layer_note": 200}}"#.utf8)) == [
            "midi.layers[0].channel: 17 is out of range, expected 1-16",
            "midi.layers[0].deck: 5 is out of range, expected 1-4",
            "midi.layer_note: 200 is out of range, expected 0-127",
        ])
        #expect(Mapping.problems(in: Data(#"{"midi": {"layers": [{"channel": 1, "deck": 1}, {"channel": 1, "deck": 2}]}}"#.utf8)) == [
            "midi.layers[1].channel: channel 1 is also midi.layers[0].channel",
        ])
    }

    static let lc6000Layers = [
        Mapping.Layer(channel: 1, deck: 1), Mapping.Layer(channel: 2, deck: 2),
        Mapping.Layer(channel: 3, deck: 3), Mapping.Layer(channel: 4, deck: 4),
    ]
    static let unit = MIDIEndpoint(id: 1001, name: "Denon DJ LC6000 PRIME LC6000 PRIME Controller")

    @Test("A controller entry that follows layers (the default when the profile has them) runs as one entry per layer")
    func followingEntryExpands() {
        let entry = ControllerSettings(deck: 1, input: Self.unit, output: nil)
        #expect(ControllerSettings.expanded([entry], layers: Self.lc6000Layers) == [
            ControllerSettings(deck: 1, input: Self.unit, output: nil, channel: 1, followLayers: true),
            ControllerSettings(deck: 2, input: Self.unit, output: nil, channel: 2, followLayers: true),
            ControllerSettings(deck: 3, input: Self.unit, output: nil, channel: 3, followLayers: true),
            ControllerSettings(deck: 4, input: Self.unit, output: nil, channel: 4, followLayers: true),
        ])
    }

    @Test("Following turned off, or a profile with no layers: the entry runs as it is")
    func notFollowing() {
        let off = ControllerSettings(deck: 2, input: Self.unit, output: nil, followLayers: false)
        #expect(ControllerSettings.expanded([off], layers: Self.lc6000Layers) == [off])
        let plain = ControllerSettings(deck: 2, input: nil, output: nil)
        #expect(ControllerSettings.expanded([plain], layers: []) == [plain])
    }

    @Test("Settings saved before #79 still read, with following left to the default")
    func oldSettingsDecode() throws {
        let json = #"{"deck": 3, "input": null, "output": null}"#
        let entry = try JSONDecoder().decode(ControllerSettings.self, from: Data(json.utf8))
        #expect(entry == ControllerSettings(deck: 3, input: nil, output: nil))
        #expect(entry.followLayers == nil)
    }

    /// A rig with the LC6000 following its layers: four entries on the one unit, channels 1-4 → decks 1-4.
    static func layered() throws -> Rig {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: lc6000Layers
        ))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))   // a live Syndicate answered
        rig.osc.sent.removeAll()
        return rig
    }

    static func note(_ rig: Rig, channel: UInt8, _ note: UInt8, _ velocity: UInt8) {
        rig.coordinator.midi(.noteOn(channel: channel - 1, note: note, velocity: velocity), source: Rig.lc6000.id)
    }

    @Test("Deck select back onto the same layer (#426): the unit's deck-select mode cleared its LEDs, so they all go out again")
    func sameLayerRepaints() throws {
        let rig = try Self.layered()
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        let painted = Set(output.sent.compactMap { if case .noteOn(_, let note, _) = $0 { note } else { nil } })
        output.sent.removeAll()
        Self.note(rig, channel: 16, 55, 127)   // the unit's deck-select mode: pads 1-4 blink
        Self.note(rig, channel: 1, 51, 127)    // pad 1 picked: layer 1, already the active one
        Self.off(rig, channel: 16, 55)
        let again = Set(output.sent.compactMap { if case .noteOn(_, let note, _) = $0 { note } else { nil } })
        #expect(again.isSuperset(of: painted))
    }

    @Test("Shift + deck select from layer 1 to 2, then a control on ch2: layer 2 is the active one")
    func activeLayer() throws {
        let rig = try Self.layered()
        #expect(rig.coordinator.status.controllers.map(\.deck) == [1, 2, 3, 4])
        Self.note(rig, channel: 16, 55, 127)   // Shift + deck select, on ch16: the unit's own
        Self.note(rig, channel: 1, 51, 0)
        Self.note(rig, channel: 2, 51, 127)
        Self.touch(rig, channel: 2)              // the first control from layer 2 confirms it
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, true, false, false])
    }

    /// A plain deck select (#420): the LC6000's Slip button, note 23 on ch1, with no Shift.
    static func deckSelect(_ rig: Rig) {
        note(rig, channel: 1, 23, 127)
        rig.coordinator.midi(.noteOff(channel: 0, note: 23, velocity: 0), source: Rig.lc6000.id)
    }

    @Test("A plain deck select steps the layer 1 → 2 → 3 → 4 → 1, and sends no OSC (no CueSlip)")
    func deckSelectSteps() throws {
        let rig = try Self.layered()
        var active: [Int] = []
        for _ in 0..<4 {
            Self.deckSelect(rig)
            active.append(rig.coordinator.status.controllers.firstIndex(where: \.activeLayer).map { $0 + 1 } ?? 0)
        }
        #expect(active == [2, 3, 4, 1])
        #expect(rig.osc.sent == [])
    }

    @Test("A plain deck select releases what the old deck held, then Play on ch1 goes to the new deck")
    func deckSelectHandsOver() throws {
        let rig = try Self.layered()
        Self.note(rig, channel: 1, 2, 127)       // Cue held on deck 1
        rig.osc.sent.removeAll()
        Self.deckSelect(rig)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)])])
        rig.osc.sent.removeAll()
        Self.note(rig, channel: 1, 1, 127)       // Play, on ch1 as the unit sends it
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)])])
    }

    @Test("With Follow controller layers off, a plain deck select does nothing: no OSC, and Play stays on the entry's deck")
    func deckSelectNotFollowing() throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.setControllers([ControllerSettings(deck: 3, input: Rig.lc6000, output: Rig.lc6000Out, followLayers: false)])
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/3/Playing", [.int(0)]))
        rig.osc.sent.removeAll()
        Self.deckSelect(rig)
        #expect(rig.osc.sent == [])
        Self.note(rig, channel: 1, 1, 127)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/3/PlayPause", [.int(1)])])
        #expect(rig.coordinator.status.controllers.map(\.deck) == [3])
    }

    @Test("Leaving a layer releases what was held on its deck, once, at the note 51 handover; Play on ch2 then goes to deck 2")
    func switchReleasesHolds() throws {
        let rig = try Self.layered()
        Self.note(rig, channel: 1, 2, 127)       // Cue held on layer 1
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/Cue", [.int(1)])])
        rig.osc.sent.removeAll()

        Self.note(rig, channel: 16, 55, 127)     // Shift + deck select
        Self.note(rig, channel: 1, 51, 0)
        Self.note(rig, channel: 2, 51, 127)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)])])
        rig.osc.sent.removeAll()

        Self.note(rig, channel: 2, 1, 127)       // Play on ch2
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)])])
    }

    @Test("Switching to a layer repaints its LEDs on its channel from its deck: deck 2 playing lights Play on ch2")
    func activationRepaints() throws {
        let rig = try Self.layered()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        output.sent.removeAll()

        Self.note(rig, channel: 1, 51, 0)
        Self.note(rig, channel: 2, 51, 127)
        Self.touch(rig, channel: 2)
        // Play is note 1; ch2 is channel 1 counted from 0. Lit full: deck 2 is playing.
        #expect(output.sent.contains(.noteOn(channel: 1, note: 1, velocity: 127)))
    }

    static func fader(_ rig: Rig, channel: UInt8, _ msb: UInt8) {
        rig.coordinator.midi(.controlChange(channel: channel - 1, controller: 8, value: msb), source: Rig.lc6000.id)
    }

    /// Shift + deck select as the real unit sends it (the CoS's clean capture): note 51 vel 0 always on ch1, whatever
    /// the old layer was, then note 51 vel 127 on the new layer's channel; then the first control from the new layer
    /// (a Play release: no OSC), which is what confirms the switch. `from` is kept for the reader.
    static func switchLayer(_ rig: Rig, from: UInt8, to: UInt8) {
        Self.note(rig, channel: 16, 55, 127)
        Self.note(rig, channel: 1, 51, 0)
        Self.note(rig, channel: to, 51, 127)
        Self.touch(rig, channel: to)
    }

    /// A control from the unit on `channel` that sends no OSC: Play released (Play triggers on press only).
    static func touch(_ rig: Rig, channel: UInt8) {
        rig.coordinator.midi(.noteOff(channel: channel - 1, note: 1, velocity: 0), source: Rig.lc6000.id)
    }

    @Test("The one pitch fader is shared by the layers: back on a layer, its deck waits for pickup instead of jumping")
    func sharedFaderPicksUpAgain() throws {
        let rig = try Self.layered()
        for deck in 1...2 {
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/\(deck)/Loaded", [.int(1)]))
            rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/\(deck)/TempoSlider", [.float(0)]))
        }
        Self.switchLayer(rig, from: 1, to: 2)
        Self.fader(rig, channel: 2, 0x40)              // center: deck 2 picks up at 0.0
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/2/TempoSlider", [.float(0)]))

        Self.switchLayer(rig, from: 2, to: 1)
        Self.fader(rig, channel: 1, 0x7F)              // the fader goes to the top on layer 1
        Self.switchLayer(rig, from: 1, to: 2)
        rig.osc.sent.removeAll()

        Self.fader(rig, channel: 2, 0x7E)              // 0.96887: far from deck 2's 0.0, so nothing
        #expect(rig.osc.sent == [])
        Self.fader(rig, channel: 2, 0x40)              // back across 0.0: picked up
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/TempoSlider", [.float(0)])])
    }

    @Test("With the device on automatic, all four layers share the one unit; a second following entry waits for another unit")
    func automaticLayersShareTheUnit() throws {
        let rig = try Rig()
        rig.coordinator.start()
        let automatic = ControllerSettings(deck: 1, input: nil, output: nil)
        rig.coordinator.setControllers(ControllerSettings.expanded([automatic], layers: Self.lc6000Layers))
        #expect(rig.coordinator.status.controllers.map(\.connected) == [true, true, true, true])

        // Two following entries would put two decks on each channel: the second one's layers wait for a second unit.
        rig.coordinator.setControllers(ControllerSettings.expanded([automatic, automatic], layers: Self.lc6000Layers))
        #expect(rig.coordinator.status.controllers.map(\.connected) == [true, true, true, true, false, false, false, false])
    }

    @Test("For the menu, a unit's layers fold into one controller: the active layer's, marked as following layers")
    func statusFoldsLayers() throws {
        let rig = try Self.layered()
        #expect(rig.coordinator.status.controllers.map(\.followsLayers) == [true, true, true, true])
        // Before any layer signal, the first layer stands for the unit.
        #expect(rig.coordinator.status.collapsingLayers().controllers.map(\.deck) == [1])

        Self.switchLayer(rig, from: 1, to: 2)
        let folded = rig.coordinator.status.collapsingLayers().controllers
        #expect(folded.count == 1)
        #expect(folded.first?.deck == 2)
        #expect(folded.first?.followsLayers == true)
        #expect(folded.first?.connected == true)
    }

    @Test("Controllers that don't follow layers are left as they are")
    func plainControllersUnfolded() throws {
        let rig = try Rig()
        rig.coordinator.start()
        #expect(rig.coordinator.status.collapsingLayers() == rig.coordinator.status)
    }

    static func off(_ rig: Rig, channel: UInt8, _ note: UInt8) {
        rig.coordinator.midi(.noteOff(channel: channel - 1, note: note, velocity: 0), source: Rig.lc6000.id)
    }

    /// The user's long hold of Shift + deck select on the real LC6000 (the CoS's capture): no note 51 handover, a
    /// ch2 note 54 instead, and the next Play still on ch1. The unit didn't change layer, so neither may the bridge.
    static func longHoldCapture(_ rig: Rig) {
        Self.note(rig, channel: 1, 26, 127)      // 13.166 Shift down
        Self.note(rig, channel: 16, 55, 127)     // 14.629 deck select down
        Self.off(rig, channel: 1, 26)            // 14.881 Shift up
        Self.note(rig, channel: 2, 54, 127)      // 16.891 no note 51 this time
        Self.off(rig, channel: 16, 55)           // 16.926 deck select up, held about 2.3 s
    }

    @Test("The long hold, from launch (ch2 note 54, then Play on ch1): the menu and Play agree on the deck")
    func longHoldWithoutHandover() throws {
        let rig = try Self.layered()
        Self.longHoldCapture(rig)
        Self.note(rig, channel: 1, 1, 127)       // 17.826 Play on ch1
        // The ch2 control made layer 2 active; ch1 controls then go to the active layer. What the user saw (menu 2,
        // Play to deck 1) can't happen: both say deck 2.
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)]))
        #expect(rig.coordinator.status.collapsingLayers().controllers.map(\.deck) == [2])
    }

    @Test("From layer 2, the long hold then Play on ch1: the menu and Play agree on the deck")
    func longHoldFromLayerTwo() throws {
        let rig = try Self.layered()
        Self.switchLayer(rig, from: 1, to: 2)
        Self.longHoldCapture(rig)
        Self.note(rig, channel: 1, 1, 127)       // 17.826 Play on ch1
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)]))
        #expect(rig.coordinator.status.collapsingLayers().controllers.map(\.deck) == [2])
    }

    @Test("The unit's real handovers (vel 0 always on ch1), each confirmed by a control: exactly the new layer is active")
    func realHandovers() throws {
        let rig = try Self.layered()
        Self.note(rig, channel: 1, 51, 0); Self.note(rig, channel: 2, 51, 127); Self.touch(rig, channel: 2)   // 16.682 → 2
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, true, false, false])
        Self.note(rig, channel: 1, 51, 0); Self.note(rig, channel: 1, 51, 127); Self.touch(rig, channel: 1)   // 19.323 → 1
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [true, false, false, false])
        Self.note(rig, channel: 1, 51, 0); Self.note(rig, channel: 3, 51, 127); Self.touch(rig, channel: 3)   // 21.655 → 3
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, false, true, false])
        Self.note(rig, channel: 1, 51, 0); Self.note(rig, channel: 4, 51, 127); Self.touch(rig, channel: 4)   // 24.426 → 4
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, false, false, true])
        #expect(rig.coordinator.status.collapsingLayers().controllers.map(\.deck) == [4])
    }

    @Test("Leaving layer 2 by a real handover releases Cue held on deck 2, once; nothing is released on deck 1")
    func realHandoverReleasesTheLayerLeft() throws {
        let rig = try Self.layered()
        Self.note(rig, channel: 1, 51, 0); Self.note(rig, channel: 2, 51, 127)
        Self.note(rig, channel: 2, 2, 127)                                           // Cue held on layer 2
        rig.osc.sent.removeAll()
        Self.note(rig, channel: 1, 51, 0); Self.note(rig, channel: 3, 51, 127)
        Self.touch(rig, channel: 3)                                                  // → layer 3
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/Cue", [.int(0)])])
    }

    static func channelsWritten(_ output: Rig.FakeOutput) -> Set<UInt8> {
        Set(output.sent.compactMap { if case .noteOn(let c, _, _) = $0 { c + 1 } else { nil } })
    }

    @Test("Only the layer in front writes LEDs: layer 1 at launch; after a handover to 2, deck 1 feedback writes nothing")
    func onlyTheShownLayerWritesLEDs() throws {
        let rig = try Rig()
        rig.coordinator.start(controllers: ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: Self.lc6000Layers
        ))
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        #expect(Self.channelsWritten(output) == [1])
        output.sent.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))   // layer 2 isn't in front
        #expect(output.sent.isEmpty)

        Self.switchLayer(rig, from: 1, to: 2)
        #expect(Self.channelsWritten(output) == [2])                                     // the repaint
        output.sent.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))   // the probe's ch1 writes
        #expect(output.sent.isEmpty)
    }


    /// The LC6000 after a power cycle (the CoS's capture): deck select moves only the layer signal, and every control
    /// stays on ch1. So in this, its normal state, it's a one-channel controller with a layer indicator.
    @Test("Normal mode: note 51 sets the layer; Play and Cue on ch1 go to that layer's deck; leaving releases its holds")
    func normalModeCapture() throws {
        let rig = try Self.layered()
        Self.note(rig, channel: 2, 51, 127)      // 29.652 layer 2 (no ch1 v0 this time)
        #expect(rig.coordinator.status.collapsingLayers().controllers.map(\.deck) == [2])
        Self.note(rig, channel: 1, 1, 127)       // 30.549 Play on ch1
        Self.note(rig, channel: 1, 2, 127)       // 32.329 Cue on ch1, held
        #expect(rig.osc.sent.suffix(2) == [
            OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)]), OSCMessage("/Syndicate/Deck/2/Cue", [.int(1)]),
        ])
        rig.osc.sent.removeAll()
        Self.note(rig, channel: 1, 51, 0)        // 36.354 layer 3
        Self.note(rig, channel: 3, 51, 127)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/Cue", [.int(0)])])
        #expect(rig.coordinator.status.collapsingLayers().controllers.map(\.deck) == [3])
        Self.note(rig, channel: 1, 1, 127)       // 36.909 Play on ch1
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/3/PlayPause", [.int(1)]))
    }

    @Test("Normal mode LEDs: the active deck's LEDs go out on ch1, where its controls are, and repaint on a layer change")
    func normalModeLEDsOnChannelOne() throws {
        let rig = try Self.layered()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        output.sent.removeAll()
        Self.note(rig, channel: 2, 51, 127)      // layer 2, controls still on ch1
        // Deck 2's Play LED (playing: 127), repainted on ch1 (channel 0 counted from 0); nothing on ch2.
        #expect(output.sent.contains(.noteOn(channel: 0, note: 1, velocity: 127)))
        #expect(Self.channelsWritten(output) == [1])
    }

    @Test("Multi-channel mode (capture 2): controls on ch2 go to deck 2, make layer 2 active, and its LEDs go on ch2")
    func multiChannelMode() throws {
        let rig = try Self.layered()
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        Self.note(rig, channel: 1, 51, 0); Self.note(rig, channel: 2, 51, 127)
        Self.note(rig, channel: 2, 1, 127)       // Play on ch2
        #expect(rig.osc.sent.last == OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)]))
        output.sent.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        #expect(Self.channelsWritten(output) == [2])
        #expect(rig.coordinator.status.collapsingLayers().controllers.map(\.deck) == [2])
    }

    // #122: the ring shows the deck the layer drives, so a layer change visibly changes it. Deck 2's badge #ECCF65 is
    // yellow (255, 255, 0), 3,3,0 = 60.

    @Test("Normal mode: switching to layer 2 with deck 2 loaded repaints the ring on ch1 in deck 2's color, 60")
    func normalModeRingInDeckColor() throws {
        let rig = try Self.layered()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        output.sent.removeAll()
        Self.note(rig, channel: 2, 51, 127)
        #expect(output.sent.last { if case .noteOn(0, 40, _) = $0 { true } else { false } } == .noteOn(channel: 0, note: 40, velocity: 60))
    }

    @Test("Multi-channel mode: with layer 2 in front, deck 2's ring goes out on ch2 in deck 2's color, 60")
    func multiChannelRingInDeckColor() throws {
        let rig = try Self.layered()
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        Self.note(rig, channel: 1, 51, 0); Self.note(rig, channel: 2, 51, 127)
        Self.note(rig, channel: 2, 1, 127)       // Play on ch2: controls on ch2
        output.sent.removeAll()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(1)]))
        #expect(output.sent.contains(.noteOn(channel: 1, note: 40, velocity: 60)))
    }

    @Test("A profile swap on layer 3 stays on layer 3: ch1 Play goes to deck 3, and only layer 3 paints the LEDs (#115)")
    func swapKeepsLayer() throws {
        let rig = try Self.layered()
        Self.switchLayer(rig, from: 1, to: 3)
        Self.touch(rig, channel: 1)              // the unit's normal state: controls, and so layer 3's LEDs, on ch1
        let output = try #require(rig.midi.outputs[Rig.lc6000Out.id])
        output.sent.removeAll()
        var mapping = try Mapping.bundledDefault()
        mapping.notes.buttons["play"] = 60
        rig.coordinator.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: mapping)])
        // One layer shown, so one Play LED write, not one per layer, and on ch1, where the unit's controls are.
        #expect(output.sent.filter { if case .noteOn(_, 60, _) = $0 { true } else { false } } == [.noteOn(channel: 0, note: 60, velocity: 1)])
        rig.osc.sent.removeAll()
        Self.note(rig, channel: 1, 60, 127)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/3/PlayPause", [.int(1)])])
    }

    @Test("A swap to a profile without layers falls back to each entry's own deck: ch1 Play goes to deck 1 (#115)")
    func swapToNoLayers() throws {
        let rig = try Self.layered()
        Self.switchLayer(rig, from: 1, to: 3)
        var mapping = try Mapping.bundledDefault()
        mapping.midi.layers = []
        mapping.midi.layerNote = nil
        rig.coordinator.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: mapping)])
        rig.osc.sent.removeAll()
        Self.note(rig, channel: 1, 1, 127)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])])
        #expect(rig.coordinator.status.controllers.map(\.activeLayer) == [false, false, false, false])
    }

    @Test("Swap to a flat profile and back: layer-following is on again, and ch1 Play after a switch to layer 2 goes to deck 2 (#133)")
    func swapBackFollows() throws {
        let rig = try Self.layered()
        var flat = try Mapping.bundledDefault()
        flat.midi.layers = []
        flat.midi.layerNote = nil
        rig.coordinator.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: flat)])
        var layered = try Mapping.bundledDefault()
        layered.osc.port = 9091   // a change, so the swap back happens
        rig.coordinator.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: layered)])
        #expect(rig.coordinator.status.controllers.map(\.followsLayers) == [true, true, true, true])
        Self.switchLayer(rig, from: 1, to: 2)
        Self.touch(rig, channel: 1)              // the unit's normal state: controls on ch1, whatever the layer
        rig.osc.sent.removeAll()
        Self.note(rig, channel: 1, 1, 127)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/2/PlayPause", [.int(1)])])
    }

    @Test("An entry set not to follow layers stays not following through a swap to flat and back (#133)")
    func swapBackKeepsOptOut() throws {
        let rig = try Rig()
        rig.coordinator.start()
        var entries = ControllerSettings.expanded([ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: Self.lc6000Layers)
        entries[1].followLayers = false
        rig.coordinator.setControllers(entries)
        var flat = try Mapping.bundledDefault()
        flat.midi.layers = []
        flat.midi.layerNote = nil
        rig.coordinator.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: flat)])
        var layered = try Mapping.bundledDefault()
        layered.osc.port = 9091
        rig.coordinator.setProfiles([ControllerProfile(id: "custom", name: "Custom mapping", deviceHints: ["LC6000"], mapping: layered)])
        #expect(rig.coordinator.status.controllers.map(\.followsLayers) == [true, false, true, true])
    }

    /// The real unit's two ports, as macOS lists them: the jog display's (WD) first, then the controls'.
    static let wdIn = MIDIEndpoint(id: 11, name: "Denon DJ LC6000 PRIME WD")
    static let controlsIn = MIDIEndpoint(id: 12, name: "Denon DJ LC6000 PRIME LC6000 PRIME Controller")
    static let wdOut = MIDIEndpoint(id: 13, name: "Denon DJ LC6000 PRIME WD")
    static let controlsOut = MIDIEndpoint(id: 14, name: "Denon DJ LC6000 PRIME LC6000 PRIME Controller")

    static func realUnit(destinations: [MIDIEndpoint] = [wdOut, controlsOut]) throws -> (Coordinator, Rig.FakeMIDISystem) {
        let midi = Rig.FakeMIDISystem(sources: [wdIn, controlsIn], destinations: destinations)
        let coordinator = Coordinator(
            profiles: try ControllerProfile.bundled(), midi: midi, osc: Rig.FakeOSC(), clock: Rig.FakeClock(), log: Rig.FakeLog()
        )
        coordinator.start(
            controllers: ControllerSettings.expanded([ControllerSettings(deck: 1, input: nil, output: nil)], layers: lc6000Layers),
            ledsEnabled: true
        )
        coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
        return (coordinator, midi)
    }

    @Test("Every layer's LEDs go to the controls' port, never the jog display's (WD): layer 2 lights deck 2's Play there, WD gets nothing")
    func layersShareTheControlsPort() throws {
        let (coordinator, midi) = try Self.realUnit()
        coordinator.midi(.noteOn(channel: 0, note: 51, velocity: 127), source: Self.controlsIn.id)
        coordinator.midi(.noteOn(channel: 1, note: 51, velocity: 127), source: Self.controlsIn.id)   // to layer 2
        #expect(midi.outputs[Self.wdOut.id]?.sent ?? [] == [])
        #expect((midi.outputs[Self.controlsOut.id]?.sent ?? []).last { if case .noteOn(_, 1, _) = $0 { true } else { false } }
            == .noteOn(channel: 0, note: 1, velocity: 127))   // normal mode: on ch1, where the controls are
    }

    @Test("If the controls' output doesn't share its input's name, the LEDs still never go to a port the profile excludes (WD)")
    func excludedPortNeverGetsLEDs() throws {
        let renamedOut = MIDIEndpoint(id: 15, name: "LC6000 PRIME Controller")
        let (coordinator, midi) = try Self.realUnit(destinations: [Self.wdOut, renamedOut])
        coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        #expect(midi.outputs[Self.wdOut.id]?.sent ?? [] == [])
        // Bound first: #expect((x?.y ?? []).contains(z)) passes when x is nil (Swift Testing's expansion of the call).
        let sent = midi.outputs[renamedOut.id]?.sent ?? []
        #expect(sent.contains(.noteOn(channel: 0, note: 1, velocity: 127)))
    }

    @Test("An output port that appears after its controller connected is opened, and the LEDs paint into it (#148)")
    func lateOutputPortIsOpened() throws {
        let midi = Rig.FakeMIDISystem(sources: [Self.controlsIn], destinations: [])
        let coordinator = Coordinator(
            profiles: try ControllerProfile.bundled(), midi: midi, osc: Rig.FakeOSC(), clock: Rig.FakeClock(), log: Rig.FakeLog()
        )
        coordinator.start(controllers: [ControllerSettings(deck: 1, input: nil, output: nil, followLayers: false)], ledsEnabled: true)
        coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))   // no output yet: nowhere to send

        midi.destinations = [Self.controlsOut]
        coordinator.devicesChanged()
        coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        let sent = midi.outputs[Self.controlsOut.id]?.sent ?? []
        #expect(sent.contains(.noteOn(channel: 0, note: 1, velocity: 127)))
    }

    @Test("Connecting says where the LEDs go, or that no output was found, so a dark unit can be diagnosed from the log")
    func connectLogsTheLEDOutput() throws {
        let midi = Rig.FakeMIDISystem(sources: [Self.wdIn, Self.controlsIn], destinations: [Self.wdOut, Self.controlsOut])
        let log = Rig.FakeLog()
        let coordinator = Coordinator(profiles: try ControllerProfile.bundled(), midi: midi, osc: Rig.FakeOSC(), clock: Rig.FakeClock(), log: log)
        coordinator.start(controllers: [ControllerSettings(deck: 1, input: nil, output: nil, followLayers: false)], ledsEnabled: true)
        #expect(log.lines.contains("LEDs go to Denon DJ LC6000 PRIME LC6000 PRIME Controller"))

        let none = Rig.FakeMIDISystem(sources: [Self.controlsIn], destinations: [Self.wdOut])
        let noneLog = Rig.FakeLog()
        let alone = Coordinator(profiles: try ControllerProfile.bundled(), midi: none, osc: Rig.FakeOSC(), clock: Rig.FakeClock(), log: noneLog)
        alone.start(controllers: [ControllerSettings(deck: 1, input: nil, output: nil, followLayers: false)], ledsEnabled: true)
        #expect(noneLog.lines.contains("No LED output found for Denon DJ LC6000 PRIME LC6000 PRIME Controller, so its LEDs stay dark"))
    }
}
