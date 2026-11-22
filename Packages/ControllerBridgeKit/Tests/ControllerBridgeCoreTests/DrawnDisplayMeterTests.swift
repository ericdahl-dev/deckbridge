import Foundation
@testable import ControllerBridgeCore
import Testing

/// The drawn display's level meter (#461): the deck in front's mixer channel, from Syndicate's Mixer/CHn/Meter, with a
/// peak hold, through the Coordinator on a fake display port.
@Suite("Drawn display: the level meter")
struct DrawnDisplayMeterTests {
    typealias Handshake = DrawnDisplayHandshakeTests

    static func meters(_ port: Handshake.Port) -> [[UInt8]] { Handshake.drawn(port).filter { $0[9] == 0x0A } }
    static func meters(_ port: JogDisplayDriverTests.FakePort) -> [[UInt8]] { Handshake.drawn(port).filter { $0[9] == 0x0A } }
    static func level(_ rig: ProfileMatchingTests.ProfileRig, channel: Int = 1, _ value: Float) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH\(channel)/Meter", [.float(value)]))
    }

    /// A level rising 0.4 dB every 10 ms from −30 dB at step 0 (#605): 0.8 dB, about 2 of the 127 steps, between two
    /// live ticks 20 ms apart, so the shown level changes at every one of them.
    static func rising(_ step: Int) -> Float { Float(pow(10, (-30 + 0.4 * Double(step)) / 20)) }

    static func drawing() throws -> (ProfileMatchingTests.ProfileRig, Handshake.Port) {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        rig.coordinator.tick()
        port.wd.removeAll()
        return (rig, port)
    }

    @Test("Drawing: the front deck's channel level goes out as op 0A (−36..+16 dB → 0-127, #582), on the 20 ms live cadence (#605), only on change")
    func meterFromFeedback() throws {
        let (rig, port) = try Self.drawing()
        rig.clock.now = 0.04   // a live tick: the one at 0, then 0.02 passed with no tick
        Self.level(rig, 0.5)
        Self.level(rig, channel: 2, 1.0)   // another deck's channel: not shown
        rig.coordinator.tick()
        // 0.5 is −6.0 dB: (−6.02 + 36) / 52 of 127, 73.
        #expect(Self.meters(port) == [DrawnDisplay.Message.meter(level: 73, peak: 73).bytes])
        port.wd.removeAll()
        for step in 5...100 {
            rig.clock.now = Double(step) * 0.01
            Self.level(rig, Self.rising(step))
            rig.coordinator.tick()
        }
        // Live ticks 20 ms apart from 0.04: 0.06 to 1.00, 48 of them, the level changed at each.
        #expect(Self.meters(port).count == 48)
        port.wd.removeAll()
        rig.clock.now = 2
        rig.coordinator.tick()
        rig.clock.now = 2.5
        rig.coordinator.tick()
        let settled = Self.meters(port).count
        rig.clock.now = 3
        rig.coordinator.tick()
        #expect(Self.meters(port).count == settled)   // nothing new: nothing sent
    }

    /// #582, #592, #605: the meter goes on the needle's shared live cadence, 20 ms, so the chip draws both in one redraw.
    @Test("The meter goes only on live ticks, every 20 ms with the needle: over a second of rising level, 50, all on even ticks")
    func fullRate() throws {
        let (rig, port) = try Self.drawing()
        var sentAt: [Int] = []
        for step in 0..<100 {
            rig.clock.now = 1 + Double(step) * 0.01
            Self.level(rig, Self.rising(step))   // above the −36 dB floor from the start, changing at every live tick
            let before = Self.meters(port).count
            rig.coordinator.tick()
            if Self.meters(port).count > before { sentAt.append(step) }
        }
        #expect(sentAt == Array(stride(from: 0, to: 100, by: 2)))
    }

    /// #582: the ballistics (MeterBallistics). The level falls from full to empty in 0.5 s rather than dropping to the
    /// latest sample; the peak holds 0.3 s, then falls at the same rate instead of snapping to the level.
    /// On the dB scale (#582) 1.0 is 0 dB, 0.692 of full (88).
    @Test("The level falls smoothly and the peak holds 0.3 s, then falls: 1.0, then 0.25 after 0.05 s")
    func peakHold() throws {
        let (rig, port) = try Self.drawing()
        Self.level(rig, 1.0)
        rig.clock.now = 0.05
        rig.coordinator.tick()
        #expect(Self.meters(port).last == DrawnDisplay.Message.meter(level: 88, peak: 88).bytes)
        Self.level(rig, 0.25)
        rig.clock.now = 0.1
        rig.coordinator.tick()
        // 0.692 less 0.05 s of fall (0.1): 0.592, 75; the peak still held at 88.
        #expect(Self.meters(port).last == DrawnDisplay.Message.meter(level: 75, peak: 88).bytes)
        rig.clock.now = 0.4
        rig.coordinator.tick()
        // 0.35 s of fall (0.7) empties it. The peak held to 0.35, then 0.05 s of fall: 0.592, 75.
        #expect(Self.meters(port).last == DrawnDisplay.Message.meter(level: 0, peak: 75).bytes)
    }

    @Test("A hit between two sends shows at the next send: 0.9 (−0.9 dB, 0.675) then 0.1 inside one 20 ms window, sent as 83, not 39")
    func hitBetweenSends() throws {
        let (rig, port) = try Self.drawing()
        Self.level(rig, 0.1)
        rig.clock.now = 1.0
        rig.coordinator.tick()
        port.wd.removeAll()
        rig.clock.now = 1.005
        Self.level(rig, 0.9)
        rig.clock.now = 1.006
        Self.level(rig, 0.1)
        for tick in [1.01, 1.02, 1.03, 1.04] {
            rig.clock.now = tick
            if tick > 1.01 { Self.level(rig, 0.1) }
            rig.coordinator.tick()
        }
        // Risen to 0.675 at 1.01, then 0.01 s of fall (0.02) by the send at 1.02: 0.655, 83; the peak 0.675, 86.
        #expect(Self.meters(port).first == DrawnDisplay.Message.meter(level: 83, peak: 86).bytes)
    }

    @Test("A steady level sends the meter once, then nothing new")
    func steadySendsNothing() throws {
        let (rig, port) = try Self.drawing()
        for step in 0..<100 {
            rig.clock.now = 1 + Double(step) * 0.01
            Self.level(rig, 0.5)
            rig.coordinator.tick()
        }
        #expect(Self.meters(port) == [DrawnDisplay.Message.meter(level: 73, peak: 73).bytes])
    }

    @Test("A deck switch moves the meter to the new deck's channel at once, in the same tick")
    func deckSwitch() throws {
        let (rig, port) = try Handshake.drawnLayers()
        Self.level(rig, channel: 1, 0.5)
        Self.level(rig, channel: 2, 0.25)
        rig.coordinator.tick()
        #expect(Self.meters(port).last == DrawnDisplay.Message.meter(level: 73, peak: 73).bytes)
        let unit = JogDisplayRingHoldTests.lc6000.id
        rig.coordinator.midi(.noteOn(channel: 0, note: 51, velocity: 0), source: unit)
        rig.coordinator.midi(.noteOn(channel: 1, note: 51, velocity: 127), source: unit)
        rig.coordinator.tick()   // same instant: the rate limit doesn't hold the new deck back
        // 0.25 is −12.0 dB: 59.
        #expect(Self.meters(port).last == DrawnDisplay.Message.meter(level: 59, peak: 59).bytes)
    }

    @Test("With no mixer feedback the meter is empty (0, 0) in the full state, not stale; a deck with none shows empty too")
    func noFeedbackIsEmpty() throws {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.jogDisplayReply(Handshake.answer)
        #expect(Self.meters(port) == [DrawnDisplay.Message.meter(level: 0, peak: 0).bytes])
        #expect(!Handshake.drawn(port).contains { $0[9] == 0x07 && $0[10] & 0x20 != 0 })   // not stale

        let (layers, wd) = try Handshake.drawnLayers()
        Self.level(layers, channel: 1, 0.5)
        layers.coordinator.tick()
        let unit = JogDisplayRingHoldTests.lc6000.id
        layers.coordinator.midi(.noteOn(channel: 0, note: 51, velocity: 0), source: unit)
        layers.coordinator.midi(.noteOn(channel: 1, note: 51, velocity: 127), source: unit)
        layers.coordinator.tick()
        #expect(Self.meters(wd).last == DrawnDisplay.Message.meter(level: 0, peak: 0).bytes)
    }

    @Test("While drawing, the mixer meter joins the required subscriptions (so a missing one is reported); not before, not after")
    func meterSubscription() throws {
        let (rig, _, _) = try Handshake.rig(.custom)
        #expect(!rig.coordinator.status.requiredSubscriptions.contains(.mixerMeter))   // still asking
        rig.coordinator.jogDisplayReply(Handshake.answer)
        #expect(rig.coordinator.status.requiredSubscriptions.contains(.mixerMeter))
        rig.coordinator.setJogDisplay(enabled: false)
        #expect(!rig.coordinator.status.requiredSubscriptions.contains(.mixerMeter))
    }
}
