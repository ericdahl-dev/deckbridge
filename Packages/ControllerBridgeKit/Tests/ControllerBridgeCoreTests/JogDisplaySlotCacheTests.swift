import Foundation
@testable import ControllerBridgeCore
import Testing

/// Every deck's beat images stay on the unit (#424): deck N's beat B lives in slot (N - 1) × 4 + B, of the 15 slots the
/// unit can show, so a deck switch is one show message and no upload. Deck 4 has three slots: on beat 4 its screen holds.
@Suite("Jog display slot cache")
struct JogDisplaySlotCacheTests {
    typealias Port = JogDisplayDriverTests.FakePort

    static func content(_ deck: Int, title: String? = nil) -> JogDisplayContent {
        JogDisplayContent(deck: deck, color: [255, 0, 0], title: title)
    }

    /// The slot of each upload in `port`'s WD messages: 0E's first payload byte.
    static func uploadSlots(_ port: Port) -> [UInt8] {
        port.wd.filter { $0.count > 9 && $0[6] == 0x0E }.map { $0[9] }
    }

    /// Answers uploads until none is in flight; returns every slot uploaded, in order.
    static func settle(_ driver: JogDisplayDriver, _ port: Port) -> [UInt8] {
        var slots: [UInt8] = []
        while driver.uploading {
            slots += uploadSlots(port)
            JogDisplayRingHoldTests.answer(driver, port)
        }
        return slots
    }

    /// A connected beat-mode driver with deck 1 in front and decks 2 and 3 kept, all stored.
    static func cached() throws -> (JogDisplayDriver, Port) {
        let rig = try Rig()
        let port = Port()
        let driver = JogDisplayRingHoldTests.driver(rig, port)
        driver.connect()
        driver.show(content(1))
        driver.keep(content(2))
        driver.keep(content(3))
        #expect(settle(driver, port) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        port.wd.removeAll()
        return (driver, port)
    }

    @Test("Decks 1-3 go up into slots 1-12, the deck in front first; a switch to deck 2 is one show of its slot, no upload")
    func switchShowsCachedSlot() throws {
        let (driver, port) = try Self.cached()
        driver.show(Self.content(2))
        #expect(port.wd == [JogDisplay.show(slot: 5)])
        #expect(!driver.uploading)
    }

    @Test("A new track on deck 3 (not in front) goes up into its slots 9-12 only; deck 1 stays on screen, beat by beat")
    func backgroundDeckReuploads() throws {
        let (driver, port) = try Self.cached()
        driver.keep(Self.content(3, title: "Night Drive"))
        #expect(Self.settle(driver, port) == [9, 10, 11, 12])
        port.wd.removeAll()
        driver.masterBeat(2)
        #expect(port.wd == [JogDisplay.show(slot: 2)])
    }

    @Test("New tracks on deck 3 and on deck 1 in front at once: deck 1's slots go first")
    func frontDeckFirst() throws {
        let (driver, port) = try Self.cached()
        driver.keep(Self.content(3, title: "Night Drive"))   // slot 9 is on the wire
        driver.show(Self.content(1, title: "Daybreak"))
        #expect(Self.settle(driver, port) == [9, 1, 2, 3, 4, 10, 11, 12])
    }

    @Test("Deck 4 has three slots, 13-15: on beat 4 nothing is sent, so its screen holds beat 3's image")
    func deckFourHoldsBeatFour() throws {
        let (driver, port) = try Self.cached()
        driver.show(Self.content(4))
        #expect(Self.settle(driver, port) == [13, 14, 15])
        port.wd.removeAll()
        for beat in [2, 3, 4, 1] { driver.masterBeat(beat) }
        #expect(port.wd == [JogDisplay.show(slot: 14), JogDisplay.show(slot: 15), JogDisplay.show(slot: 13)])
    }

    @Test("Custom display firmware shows 16 slots (#425): deck 4 gets all four, and beat 4 shows slot 16")
    func customFirmwareGivesDeckFourItsFourthBeat() throws {
        let (driver, port) = try Self.cached()
        driver.displayFirmware = .custom
        driver.reply(JogDisplayDriverTests.refused)   // the slot 16 patch doesn't draw (#456): images
        driver.show(Self.content(4))
        #expect(Self.settle(driver, port) == [13, 14, 15, 16])
        port.wd.removeAll()
        for beat in [2, 3, 4, 1] { driver.masterBeat(beat) }
        #expect(port.wd == [14, 15, 16, 13].map { JogDisplay.show(slot: $0) })
    }

    @Test("Switching to custom firmware while deck 4 is in front uploads only its missing slot 16; back to Denon's, beat 4 holds again")
    func switchingFirmwareWhileShowing() throws {
        let (driver, port) = try Self.cached()
        driver.show(Self.content(4))
        _ = Self.settle(driver, port)
        driver.displayFirmware = .custom
        driver.reply(JogDisplayDriverTests.refused)   // the slot 16 patch doesn't draw (#456): images
        #expect(Self.settle(driver, port) == [16])
        driver.displayFirmware = .denon
        port.wd.removeAll()
        driver.masterBeat(3)
        driver.masterBeat(4)
        #expect(port.wd == [JogDisplay.show(slot: 15)])
    }

    @Test("A reconnect forgets what the unit held (it may have lost power): every deck goes up again")
    func reconnectUploadsAgain() throws {
        let (driver, port) = try Self.cached()
        driver.disconnect()
        driver.connect()
        #expect(Self.settle(driver, port) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    }

    /// The LC6000 following its four layers, with its WD port and the display on; every upload answered.
    static func layered() throws -> (ProfileMatchingTests.ProfileRig, Port, [UInt8]) {
        let (rig, port) = try JogDisplayRingHoldTests.owned()
        let unit = JogDisplayRingHoldTests.lc6000
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: unit, output: MIDIEndpoint(id: unit.id + 1000, name: unit.name))],
            layers: LayersTests.lc6000Layers))
        for deck in 1...4 { rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/\(deck)/Loaded", [.int(1)])) }
        rig.coordinator.setJogDisplay(enabled: true)
        var slots: [UInt8] = []
        var rounds = 0
        while !uploadSlots(port).isEmpty, rounds < 40 {
            slots += uploadSlots(port)
            JogDisplayRingHoldTests.answer(rig, port)
            rounds += 1
        }
        return (rig, port, slots)
    }

    @Test("Following layers, every deck's images go up after connect: deck 1's four first, then decks 2-4 (15 slots)")
    func everyLayerCached() throws {
        let (_, _, slots) = try Self.layered()
        #expect(slots == Array(1...15))
    }

    @Test("A layer switch to deck 2, once cached: its slot is shown, nothing is uploaded, and the ring is never held dark")
    func layerSwitchWithoutUpload() throws {
        let (rig, port, _) = try Self.layered()
        port.wd.removeAll()
        let before = JogDisplayRingHoldTests.ring(rig).count
        rig.coordinator.midi(.noteOn(channel: 0, note: 51, velocity: 0), source: JogDisplayRingHoldTests.lc6000.id)
        rig.coordinator.midi(.noteOn(channel: 1, note: 51, velocity: 127), source: JogDisplayRingHoldTests.lc6000.id)
        #expect(Self.uploadSlots(port).isEmpty)
        #expect(port.wd.contains(JogDisplay.show(slot: 5)))
        let since = JogDisplayRingHoldTests.ring(rig).dropFirst(before)
        #expect(!since.isEmpty && !since.contains(0))
    }

    @Test("Settings' display firmware through the pipe: with Custom, the layers' images fill all 16 slots")
    func firmwareSettingThroughThePipe() async throws {
        let (rig, port, slots) = try Self.layered()
        #expect(slots == Array(1...15))
        port.wd.removeAll()
        let pipe = EventPipe()
        pipe.producer.send(.setDisplayFirmware(.custom))
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)
        // Custom firmware is asked whether it draws (#456); this unit refuses, so it shows images.
        #expect(port.wd.contains(DrawnDisplay.Message.capability(version: DrawnDisplay.version).bytes))
        rig.coordinator.jogDisplayReply(JogDisplayDriverTests.refused)
        #expect(Self.uploadSlots(port) == [16])
    }
}
