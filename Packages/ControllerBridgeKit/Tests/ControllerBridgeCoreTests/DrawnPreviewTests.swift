@testable import ControllerBridgeCore
import Testing

/// The Diagnostics preview of the drawn layout (#465): each deck's drawn state, decoded from the messages the host
/// would send for it, whenever the jog display would draw. A unit that answered draws; one that didn't shows images;
/// with no unit, Custom shows the drawn look so it can be tried, Denon the images.
@Suite("Drawn display: the preview")
struct DrawnPreviewTests {
    static func drawnPreviews(_ events: [JogDisplayEvent]) -> [DrawnDisplayState] {
        events.compactMap { if case .drawnPreview(let state) = $0 { return state }; return nil }
    }

    @Test("No unit, Custom: every loaded deck gets a drawn preview with its deck and title")
    func noUnitCustom() throws {
        let (rig, take) = try JogDisplayPreviewNoControllerTests.rig()
        rig.coordinator.setDisplayFirmware(.custom)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/3/Loaded", [.int(1)]))
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 3))
        rig.clock.now = 0.1
        rig.coordinator.tick()
        let deck3 = Self.drawnPreviews(take()).last { $0.deck?.number == 3 }
        #expect(deck3?.texts[.title] == Array("Daybreak".utf8))
        #expect(deck3?.flags.contains(.loaded) == true)
    }

    @Test("No unit, Denon: no drawn preview; the image preview as today")
    func noUnitDenon() throws {
        let (rig, take) = try JogDisplayPreviewNoControllerTests.rig()
        rig.coordinator.setDisplayFirmware(.denon)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/3/Loaded", [.int(1)]))
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 3))
        rig.clock.now = 0.1
        rig.coordinator.tick()
        let events = take()
        #expect(Self.drawnPreviews(events).isEmpty)
        #expect(events.contains { if case .preview(let content) = $0 { return content.deck == 3 }; return false })
    }

    typealias Handshake = DrawnDisplayHandshakeTests

    /// Handshake.rig's unit (Custom, connected, asking), with the driver's events recorded.
    static func unit() throws -> (ProfileMatchingTests.ProfileRig, Rig.FakeClock, () -> [JogDisplayEvent]) {
        let rig = ProfileMatchingTests.ProfileRig(profiles: try ControllerProfile.bundled(),
                                                  sources: [JogDisplayRingHoldTests.lc6000, JogDisplayRingHoldTests.wd])
        let port = Handshake.Port(), clock = Rig.FakeClock()
        let driver = JogDisplayDriver(port: port, clock: clock, log: rig.log, size: 1,
                                      renderBeat: { _, beat in [UInt8(beat), 0, 0, 255] }) { _ in [0, 0, 0, 255] }
        var events: [JogDisplayEvent] = []
        driver.onEvent = { events.append($0) }
        rig.coordinator.attachJogDisplay(driver)
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(1)]))
        rig.coordinator.setDisplayFirmware(.custom)
        rig.coordinator.setJogDisplay(enabled: true)
        return (rig, clock, { defer { events.removeAll() }; return events })
    }

    @Test("A unit, Custom, that hasn't answered shows images: no drawn preview while it asks or after it gives up")
    func unitNoAnswer() throws {
        let (rig, clock, take) = try Self.unit()
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        rig.coordinator.tick()
        #expect(Self.drawnPreviews(take()).isEmpty)   // still asking
        clock.now = 1
        rig.clock.now = 1
        rig.coordinator.tick()
        let events = take()
        #expect(Self.drawnPreviews(events).isEmpty)   // gave up: images
    }

    @Test("A unit that answered draws: the deck in front's drawn preview")
    func unitDrawing() throws {
        let (rig, _, take) = try Self.unit()
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        rig.coordinator.jogDisplayReply(Handshake.answer)
        rig.clock.now = 0.1
        rig.coordinator.tick()
        #expect(Self.drawnPreviews(take()).last { $0.deck?.number == 1 }?.texts[.title] == Array("Daybreak".utf8))
    }

    /// #582: one implementation of the meter's ballistics for the unit and the preview.
    @Test("The preview's meter has the same ballistics and scale as the unit's: 1.0 (0 dB), then 0.05 s of fall, 75 with the peak held at 88")
    func previewMeterBallistics() throws {
        let (rig, _, take) = try Self.unit()
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        rig.coordinator.jogDisplayReply(Handshake.answer)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH1/Meter", [.float(1.0)]))
        rig.clock.now = 0.05
        rig.coordinator.tick()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH1/Meter", [.float(0.25)]))
        rig.clock.now = 0.1
        rig.coordinator.tick()
        let meter = Self.drawnPreviews(take()).last { $0.deck?.number == 1 }?.meter
        #expect(meter?.level == 75 && meter?.peak == 88)
    }

    @Test("When the unit answers, every deck's drawn preview goes at once, even with nothing new about it")
    func switchingToDrawn() throws {
        let (rig, _, take) = try Self.unit()
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        rig.coordinator.tick()
        _ = take()
        rig.coordinator.jogDisplayReply(Handshake.answer)
        rig.clock.now = 0.1
        rig.coordinator.tick()
        #expect(Self.drawnPreviews(take()).contains { $0.deck?.number == 1 })
    }

    @Test("Back to images (Firmware set to Denon): the view is told once, so it draws today's previews again")
    func backToImages() throws {
        let (rig, take) = try JogDisplayPreviewNoControllerTests.rig()
        rig.coordinator.setDisplayFirmware(.custom)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/3/Loaded", [.int(1)]))
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 3))
        rig.clock.now = 0.1
        rig.coordinator.tick()
        _ = take()
        rig.coordinator.setDisplayFirmware(.denon)
        rig.clock.now = 0.2
        rig.coordinator.tick()
        rig.clock.now = 0.3
        rig.coordinator.tick()
        let events = take()
        #expect(events.filter { $0 == .drawnPreviewsEnded }.count == 1)
        #expect(Self.drawnPreviews(events).isEmpty)
    }

    @Test("Each deck's time goes into its drawn preview: its position and length in whole seconds (#460)")
    func time() throws {
        let (rig, take) = try JogDisplayPreviewNoControllerTests.rig()
        rig.coordinator.setDisplayFirmware(.custom)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/3/Loaded", [.int(1)]))
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 3))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/3/Position", [.float(83.9)]))
        rig.clock.now = 0.1
        rig.coordinator.tick()
        let deck3 = Self.drawnPreviews(take()).last { $0.deck?.number == 3 }
        #expect(deck3?.time?.elapsed == 83 && deck3?.time?.length == 428)
    }
}
