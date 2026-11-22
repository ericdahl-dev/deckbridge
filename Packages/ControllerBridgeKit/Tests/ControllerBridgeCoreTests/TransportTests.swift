import ControllerBridgeCore
import Testing

/// Expected OSC comes from the Python bridge and its tests: triggers fire only on a press, holds send 1 then 0.
@Suite("Transport buttons")
struct TransportTests {
    static func started() throws -> Rig {
        let rig = try Rig()
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        return rig
    }

    static func press(_ rig: Rig, _ note: UInt8) {
        rig.coordinator.midi(.noteOn(channel: 0, note: note, velocity: 127), source: Rig.lc6000.id)
    }

    static func release(_ rig: Rig, _ note: UInt8) {
        rig.coordinator.midi(.noteOff(channel: 0, note: note, velocity: 0), source: Rig.lc6000.id)
    }

    @Test("Cue is a hold: press sends Cue 1, release sends Cue 0")
    func cueHold() throws {
        let rig = try Self.started()
        Self.press(rig, 2)
        Self.release(rig, 2)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/Cue", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)]),
        ])
    }

    @Test("Censor is a reverse hold: press sends Reverse 1, release sends Reverse 0")
    func censorHold() throws {
        let rig = try Self.started()
        Self.press(rig, 7)
        Self.release(rig, 7)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/Reverse", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/Reverse", [.int(0)]),
        ])
    }

    @Test("Sync and Master are triggers: TempoSync 1 and TempoMaster 1 on press, nothing on release")
    func syncAndMaster() throws {
        let rig = try Self.started()
        Self.press(rig, 20)
        Self.release(rig, 20)
        Self.press(rig, 21)
        Self.release(rig, 21)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/TempoSync", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/TempoMaster", [.int(1)]),
        ])
    }

    // #478: the panel prints OFF under Sync. With Shift held, Sync turns sync off, and only off: TempoSync toggles.

    @Test("Shift + Sync on a synced deck sends TempoSync 1 once, turning sync off; nothing on release")
    func shiftSyncTurnsSyncOff() throws {
        let rig = try Self.started()
        PickupTests.report(rig, "Sync", .int(1))
        rig.osc.sent.removeAll()
        Self.press(rig, 26)
        Self.press(rig, 20)
        Self.release(rig, 20)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/TempoSync", [.int(1)])])
    }

    @Test("Shift + Sync on a deck that isn't synced sends nothing: it never turns sync on")
    func shiftSyncNotSynced() throws {
        let rig = try Self.started()
        PickupTests.report(rig, "Sync", .int(0))
        rig.osc.sent.removeAll()
        Self.press(rig, 26)
        Self.press(rig, 20)
        Self.release(rig, 20)
        #expect(rig.osc.sent == [])
    }

    // #114: the LC6000's printed Shift functions. Pitch Bend − / + nudge the tempo while held (Syndicate §14.6).

    @Test("Pitch Bend − / + are holds: PhaseMinus or PhasePlus 1 on press, 0 on release")
    func pitchBendHolds() throws {
        let rig = try Self.started()
        Self.press(rig, 24)
        Self.release(rig, 24)
        Self.press(rig, 25)
        Self.release(rig, 25)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PhaseMinus", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/PhaseMinus", [.int(0)]),
            OSCMessage("/Syndicate/Deck/1/PhasePlus", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/PhasePlus", [.int(0)]),
        ])
    }

    @Test("A held Pitch Bend is released once by stop and once by an unplug")
    func pitchBendReleasedByStopAndUnplug() throws {
        let rig = try Self.started()
        Self.press(rig, 24)
        rig.osc.sent.removeAll()
        rig.coordinator.stop()
        Self.release(rig, 24)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhaseMinus", [.int(0)])])

        let unplugged = try Self.started()
        Self.press(unplugged, 25)
        unplugged.osc.sent.removeAll()
        unplugged.midi.sources = []
        unplugged.coordinator.devicesChanged()
        #expect(unplugged.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhasePlus", [.int(0)])])
    }

    @Test("Leaving a layer with Pitch Bend held releases it on the old deck")
    func pitchBendReleasedByLayerSwitch() throws {
        let rig = try LayersTests.layered()
        LayersTests.note(rig, channel: 1, 25, 127)
        rig.osc.sent.removeAll()
        LayersTests.switchLayer(rig, from: 1, to: 2)
        #expect(rig.osc.sent.first == OSCMessage("/Syndicate/Deck/1/PhasePlus", [.int(0)]))
        #expect(rig.osc.sent.filter { $0.address.hasSuffix("PhasePlus") }.count == 1)
    }

    @Test("Shift + Pitch Bend − / + transposes (#377): key lock on, then PitchDown or PitchUp 1, once per press; nothing on release, no nudge")
    func shiftPitchBendTransposes() throws {
        let rig = try Self.started()
        Self.press(rig, 26)   // Shift down
        Self.press(rig, 24)
        Self.release(rig, 24)
        Self.press(rig, 25)
        Self.release(rig, 25)
        Self.press(rig, 25)
        let on = OSCMessage("/Syndicate/Deck/1/PitchPreserve", [.int(1)])
        #expect(rig.osc.sent == [
            on, OSCMessage("/Syndicate/Deck/1/PitchDown", [.int(1)]),
            on, OSCMessage("/Syndicate/Deck/1/PitchUp", [.int(1)]),
            on, OSCMessage("/Syndicate/Deck/1/PitchUp", [.int(1)]),
        ])
    }

    @Test("Shift + Pitch Bend turns key lock on first, as Syndicate transposes only with P on (the user's pick): its LED lights, and the next Key Lock press turns it off")
    func transposeTurnsKeyLockOn() throws {
        let rig = try Self.started()
        Self.press(rig, 26)   // Shift down
        Self.press(rig, 25)
        Self.release(rig, 25)
        Self.release(rig, 26)
        #expect(rig.leds[22] == 127)
        rig.osc.sent.removeAll()
        Self.press(rig, 22)   // Key Lock
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PitchPreserve", [.int(0)])])
    }

    @Test("Shift + Key Lock resets the tempo: one TempoSlider 0.0, Key Lock untouched, and the fader waits to meet 0.0")
    func shiftKeyLockResetsTempo() throws {
        let rig = try Self.started()
        PickupTests.report(rig, "TempoSliderEnabled", .int(1))
        PickupTests.fader(rig, 0x60)   // the fader drives the tempo at 0.50009
        let keyLockLED = rig.leds[22]
        rig.osc.sent.removeAll()

        Self.press(rig, 26)
        Self.press(rig, 22)
        Self.release(rig, 22)
        Self.release(rig, 26)
        #expect(rig.osc.sent == [PickupTests.tempo(0.0)])
        #expect(rig.leds[22] == keyLockLED)

        // The fader is still up at 0.5: it waits until it comes back to 0.0, then drives again.
        PickupTests.fader(rig, 0x70)
        PickupTests.fader(rig, 0x50)
        #expect(rig.osc.sent == [PickupTests.tempo(0.0)])
        PickupTests.fader(rig, 0x40)
        PickupTests.fader(rig, 0x50)
        #expect(rig.osc.sent == [PickupTests.tempo(0.0), PickupTests.tempo(0.0), PickupTests.tempo(0.25008)])
    }

    @Test("Shift + Key Lock on a synced follower (tempo slider disabled) sends nothing: Syndicate ignores TempoSlider then")
    func shiftKeyLockWithSliderDisabled() throws {
        let rig = try Self.started()
        PickupTests.report(rig, "TempoSliderEnabled", .int(0))
        rig.osc.sent.removeAll()
        Self.press(rig, 26)
        Self.press(rig, 22)
        #expect(rig.osc.sent == [])
    }

    @Test("Shift + Censor latches Reverse: each press toggles it, and letting go sends nothing")
    func shiftCensorLatchesReverse() throws {
        let rig = try Self.started()
        Self.press(rig, 26)
        Self.press(rig, 7)
        Self.release(rig, 7)
        Self.press(rig, 7)
        Self.release(rig, 7)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/Reverse", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/Reverse", [.int(0)]),
        ])
    }

    @Test("A latched Reverse is turned off once by stop; with it off, stop sends nothing")
    func latchedReverseReleasedByStop() throws {
        let rig = try Self.started()
        Self.press(rig, 26)
        Self.press(rig, 7)
        Self.release(rig, 7)
        Self.release(rig, 26)
        rig.osc.sent.removeAll()
        rig.coordinator.stop()
        rig.coordinator.stop()
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/Reverse", [.int(0)])])
    }

    @Test("A plain Censor press-and-release while Reverse is latched ends it: the next Shift + Censor turns it on again")
    func censorHoldEndsLatch() throws {
        let rig = try Self.started()
        Self.press(rig, 26)
        Self.press(rig, 7)    // latched on
        Self.release(rig, 7)
        Self.release(rig, 26)
        Self.press(rig, 7)    // a hold: 1, then 0 leaves Reverse off
        Self.release(rig, 7)
        Self.press(rig, 26)
        Self.press(rig, 7)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/Reverse", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/Reverse", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/Reverse", [.int(0)]),
            OSCMessage("/Syndicate/Deck/1/Reverse", [.int(1)]),
        ])
    }

    @Test("Key Lock toggles on each press: PitchPreserve 1, then 0, and its LED follows")
    func keyLockToggles() throws {
        let rig = try Self.started()
        #expect(rig.leds[22] == 1)
        Self.press(rig, 22)
        Self.release(rig, 22)
        #expect(rig.leds[22] == 127)
        Self.press(rig, 22)
        #expect(rig.leds[22] == 1)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/PitchPreserve", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/PitchPreserve", [.int(0)]),
        ])
    }

    @Test("On a profile that maps Slip (the LC6000 doesn't, #420), it toggles on each press: CueSlip 1, then 0, and its LED follows")
    func slipToggles() throws {
        let rig = try Rig(override: #"{ "notes": { "slip": 99 } }"#)
        rig.coordinator.start()
        rig.osc.sent.removeAll()
        #expect(rig.leds[99] == 1)
        Self.press(rig, 99)
        Self.release(rig, 99)
        #expect(rig.leds[99] == 127)
        Self.press(rig, 99)
        #expect(rig.leds[99] == 1)
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/CueSlip", [.int(1)]),
            OSCMessage("/Syndicate/Deck/1/CueSlip", [.int(0)]),
        ])
    }

    @Test("The Shift LED is full while Shift is held and dim otherwise")
    func shiftLED() throws {
        let rig = try Self.started()
        #expect(rig.leds[26] == 1)
        Self.press(rig, 26)
        #expect(rig.leds[26] == 127)
        Self.release(rig, 26)
        #expect(rig.leds[26] == 1)
        #expect(rig.osc.sent == [])
    }

    static func feedback(_ rig: Rig, _ path: String, _ value: Int32) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/" + path, [.int(value)]))
    }

    @Test("The Cue LED is lit while a track is loaded and not playing")
    func cueLED() throws {
        let rig = try Self.started()
        #expect(rig.leds[2] == 1)
        Self.feedback(rig, "Loaded", 1)
        #expect(rig.leds[2] == 127)
        Self.feedback(rig, "Playing", 1)
        #expect(rig.leds[2] == 1)
        Self.feedback(rig, "Playing", 0)
        #expect(rig.leds[2] == 127)
        Self.feedback(rig, "Loaded", 0)
        #expect(rig.leds[2] == 1)
    }

    @Test("The Sync LED follows Sync; Master is lit only while synced with the tempo slider enabled")
    func syncAndMasterLEDs() throws {
        let rig = try Self.started()
        #expect(rig.leds[20] == 1)
        #expect(rig.leds[21] == 1)
        Self.feedback(rig, "Sync", 1)
        #expect(rig.leds[20] == 127)
        #expect(rig.leds[21] == 127)
        Self.feedback(rig, "TempoSliderEnabled", 0)
        #expect(rig.leds[20] == 127)
        #expect(rig.leds[21] == 1)
        Self.feedback(rig, "TempoSliderEnabled", 1)
        Self.feedback(rig, "Sync", 0)
        #expect(rig.leds[20] == 1)
        #expect(rig.leds[21] == 1)
    }

    @Test("Stop releases every held control exactly once, and a second stop sends nothing")
    func stopReleasesHolds() throws {
        let rig = try Self.started()
        Self.press(rig, 1)   // Play, a trigger: nothing to release (before Cue: with Cue held it latches, #360)
        Self.press(rig, 2)   // Cue, held
        Self.press(rig, 7)   // Censor, held
        rig.osc.sent.removeAll()

        rig.coordinator.stop()
        #expect(rig.osc.sent == [
            OSCMessage("/Syndicate/Deck/1/Cue", [.int(0)]),
            OSCMessage("/Syndicate/Deck/1/Reverse", [.int(0)]),
        ])

        rig.coordinator.stop()
        Self.release(rig, 2)
        Self.release(rig, 7)
        #expect(rig.osc.sent.count == 2)
    }

    @Test("A released hold is not released again by stop")
    func releasedHoldIsForgotten() throws {
        let rig = try Self.started()
        Self.press(rig, 2)
        Self.release(rig, 2)
        rig.osc.sent.removeAll()
        rig.coordinator.stop()
        #expect(rig.osc.sent == [])
    }

    @Test("Release-all clears Shift: its LED goes dim, and Pitch Bend + afterwards nudges instead of the Shift function")
    func releaseAllClearsShift() throws {
        let rig = try Self.started()
        Self.press(rig, 26)
        rig.coordinator.willSleep()   // release-all, ports left open
        #expect(rig.leds[26] == 1)
        Self.press(rig, 25)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Deck/1/PhasePlus", [.int(1)])])
    }
}
