import Foundation
@testable import ControllerBridgeCore
import Testing

/// The jog display controller (#384): the deck in front, the needles and the display, from plain values per controller
/// entry, not the Coordinator's or the Bridge's internals.
@Suite("Jog display controller: the deck in front")
struct JogDisplayFrontTests {
    typealias Entry = JogDisplayController.Entry

    static func entry(deck: Int, connected: Bool = true, ownsDisplay: Bool = false, activeLayer: Bool = false,
                      loaded: Bool = false) -> Entry {
        var facts = DeckFacts(deck: deck)
        facts.loaded = loaded
        return Entry(connected: connected, ownsDisplay: ownsDisplay, activeLayer: activeLayer, facts: facts)
    }

    @Test("Connected: the active layer, else the first connected entry")
    func activeLayerElseFirst() {
        #expect(JogDisplayController.front([Self.entry(deck: 1), Self.entry(deck: 2, activeLayer: true)], previewDeck: nil) == 1)
        #expect(JogDisplayController.front([Self.entry(deck: 1, connected: false), Self.entry(deck: 2)], previewDeck: nil) == 1)
        #expect(JogDisplayController.front([Self.entry(deck: 1), Self.entry(deck: 2)], previewDeck: nil) == 0)
    }

    @Test("An entry whose profile owns the display's port comes first (#305): its active layer, else its first")
    func ownerFirst() {
        let entries = [Self.entry(deck: 1, activeLayer: true), Self.entry(deck: 2, ownsDisplay: true),
                       Self.entry(deck: 3, ownsDisplay: true, activeLayer: true)]
        #expect(JogDisplayController.front(entries, previewDeck: nil) == 2)
        #expect(JogDisplayController.front(Array(entries.prefix(2)), previewDeck: nil) == 1)
    }

    @Test("None connected, the preview follows the picked deck, else the first loaded one, else the first (#221)")
    func preview() {
        let entries = [Self.entry(deck: 1, connected: false), Self.entry(deck: 2, connected: false, loaded: true),
                       Self.entry(deck: 3, connected: false)]
        #expect(JogDisplayController.front(entries, previewDeck: 3) == 2)
        #expect(JogDisplayController.front(entries, previewDeck: nil) == 1)
        #expect(JogDisplayController.front(entries, previewDeck: 4) == 1)   // no entry for deck 4: the first loaded
        #expect(JogDisplayController.front(Array(entries.prefix(1)), previewDeck: nil) == 0)
        #expect(JogDisplayController.front([], previewDeck: nil) == nil)
    }
}

/// Each deck's needle (#165, the user's pick): its own phase in the bar from DeckFacts' BarRamp at its BPM (else the
/// master's, else 120), a quarter turn a beat, never more than a quarter past the ramp; a pause holds it.
@Suite("Jog display controller: needles")
struct JogDisplayNeedleTests {
    static func playing(_ deck: Int = 1, bpm: Double?, ramp: Double, at: Double, playing: Bool = true) -> JogDisplayController.Entry {
        var facts = DeckFacts(deck: deck)
        facts.playing = playing
        facts.loaded = true
        facts.bpm = bpm
        facts.barRamp = DeckFacts.BarRamp(phase: ramp, at: at)
        return JogDisplayController.Entry(connected: true, ownsDisplay: true, activeLayer: true, facts: facts)
    }

    @Test("BarRamp 0 at 120 BPM: 0 at once, 2048 a quarter-second on (an eighth of a turn)")
    func runsAtTheDeckBPM() {
        let clock = Rig.FakeClock()
        let controller = JogDisplayController(clock: clock)
        controller.observe([Self.playing(bpm: 120, ramp: 0, at: 0)])
        #expect(controller.needle(0, at: 0) == 0)
        #expect(controller.needle(0, at: 0.25) == 2048)
    }

    @Test("No deck BPM: the master's (Header/BPM), else 120")
    func masterBPMElse120() {
        let controller = JogDisplayController(clock: Rig.FakeClock())
        controller.feedback(OSCMessage("/Syndicate/Header/BPM", [.float(60)]))
        controller.observe([Self.playing(bpm: nil, ramp: 0, at: 0)])
        #expect(controller.needle(0, at: 0.25) == 1024)   // 60 BPM: a sixteenth of a turn in a quarter-second
        let fresh = JogDisplayController(clock: Rig.FakeClock())
        fresh.observe([Self.playing(bpm: nil, ramp: 0, at: 0)])
        #expect(fresh.needle(0, at: 0.25) == 2048)
    }

    @Test("Paused, it holds where it was: BarRamp 0, paused a quarter-second on, still 2048 seconds later")
    func pauseHolds() {
        let clock = Rig.FakeClock()
        let controller = JogDisplayController(clock: clock)
        controller.observe([Self.playing(bpm: 120, ramp: 0, at: 0)])
        clock.now = 0.25
        controller.observe([Self.playing(bpm: 120, ramp: 0, at: 0, playing: false)])
        #expect(controller.needle(0, at: 5) == 2048)
    }

    @Test("A paused deck's BarRamp sets the needle without running on (a seek, #388)")
    func pausedRampSets() {
        let controller = JogDisplayController(clock: Rig.FakeClock())
        controller.observe([Self.playing(bpm: 120, ramp: 0.5, at: 1, playing: false)])
        #expect(controller.needle(0, at: 9) == 8192)
    }
}

/// The controller drives the JogDisplayDriver behind JogDisplayPort (#384): the ADR-0005 gate, the deck in front's
/// content, the needles and the master beat.
@Suite("Jog display controller: the display")
struct JogDisplayControllerDriverTests {
    typealias Port = JogDisplayDriverTests.FakePort

    final class Events: @unchecked Sendable { var list: [JogDisplayEvent] = [] }

    static func rig() -> (JogDisplayController, Port, Rig.FakeClock, Events) {
        let port = Port(), clock = Rig.FakeClock(), events = Events()
        let driver = JogDisplayDriver(port: port, clock: clock, log: Rig.FakeLog(), size: 1) { content in [UInt8(content.deck), 0, 0, 255] }
        driver.onEvent = { events.list.append($0) }
        let controller = JogDisplayController(clock: clock)
        controller.attach(driver)
        return (controller, port, clock, events)
    }

    static func entries(playing: Bool = true) -> [JogDisplayController.Entry] {
        [JogDisplayNeedleTests.playing(1, bpm: 120, ramp: 0, at: 0, playing: playing),
         JogDisplayController.Entry(connected: true, ownsDisplay: true, activeLayer: false, facts: {
             var facts = DeckFacts(deck: 2)
             facts.playing = true
             facts.bpm = 120
             facts.barRamp = DeckFacts.BarRamp(phase: 0.5, at: 0)
             return facts
         }())]
    }

    @Test("Off (ADR-0005): through a refresh, header feedback, facts and ticks, nothing reaches either port")
    func offSendsNothing() {
        let (controller, port, clock, _) = Self.rig()
        let entries = Self.entries()
        controller.refresh(entries, color: { _ in nil })
        controller.feedback(OSCMessage("/Syndicate/Header/Clock", [.int(2)]))
        controller.observe(entries)
        for step in 1...20 { clock.now = Double(step) * 0.05; controller.tick(entries) }
        #expect(port.controller == [])
        #expect(port.wd == [])
    }

    @Test("On: hello, then the deck in front's card (deck 1, the active layer), in its color")
    func onShowsFront() {
        let (controller, port, _, events) = Self.rig()
        controller.setEnabled(true)
        controller.refresh(Self.entries(), color: { [1: [255, 0, 0]][$0] })
        #expect(port.controller == JogDisplay.hello)
        #expect(events.list.contains { if case .uploadStarted(_, let content, _) = $0 { content.deck == 1 && content.color == [255, 0, 0] } else { false } })
    }

    @Test("A tick sends the deck in front's needle to the unit, and every playing deck's to the simulator")
    func tickNeedles() {
        let (controller, port, clock, events) = Self.rig()
        controller.setEnabled(true)
        let entries = Self.entries()
        controller.refresh(entries, color: { _ in nil })
        controller.observe(entries)
        port.wd.removeAll()
        clock.now = 0.25
        controller.tick(entries)
        #expect(port.wd.contains([0xE0, 0x00, 0x10]))   // deck 1: 2048
        #expect(events.list.contains(.deckMarker(deck: 2, pitchBend: 10240)))   // deck 2: 0.5 + 1/8
        #expect(!port.wd.contains([0xE0, 0x00, 0x50]))   // deck 2's isn't sent to the unit
    }

    @Test("Header/Clock's beat reaches the driver: the lit ring segment")
    func masterBeat() {
        let (controller, _, _, events) = Self.rig()
        controller.feedback(OSCMessage("/Syndicate/Header/Clock", [.int(3)]))
        #expect(events.list.contains(.masterBeat(3)))
    }
}
