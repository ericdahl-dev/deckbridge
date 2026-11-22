import Foundation
@testable import ControllerBridgeCore
import Testing

/// The Needle Drop strip moves the deck's channel fader in Syndicate (#609), on a plain touch since #729; Shift + the
/// strip seeks. The LC6000 sends the same strip CCs (64/65) and touch note (70) with Shift held as without; Shift is
/// note 26.
@Suite("Needle Drop strip fader")
struct StripFaderTests {
    typealias C = ContinuousTests

    static func note(_ rig: Rig, _ note: UInt8, _ down: Bool) {
        rig.coordinator.midi(down ? .noteOn(channel: 0, note: note, velocity: 127) : .noteOff(channel: 0, note: note, velocity: 0),
                             source: Rig.lc6000.id)
    }

    static func shift(_ rig: Rig, _ down: Bool) { note(rig, 26, down) }
    static func touch(_ rig: Rig, _ down: Bool) { note(rig, 70, down) }

    /// The strip at `position` (0-16383), MSB then LSB, as the unit sends it.
    static func at(_ rig: Rig, _ position: Int) { C.strip(rig, UInt8(position >> 7), UInt8(position & 0x7F)) }

    static func volume(_ rig: Rig, channel: Int = 1, _ level: Float) {
        rig.coordinator.feedback(OSCMessage("/Syndicate/Mixer/CH\(channel)/Volume", [.float(level)]))
    }

    /// The Volume levels sent to `channel`, in order.
    static func sentVolumes(_ rig: Rig, channel: Int = 1) -> [Float] {
        rig.osc.sent.compactMap { message in
            guard message.address == "/Syndicate/Mixer/CH\(channel)/Volume", case .float(let level)? = message.arguments.first else { return nil }
            return level
        }
    }

    static func seeks(_ rig: Rig) -> [OSCMessage] { rig.osc.sent.filter { $0.address.hasSuffix("/WaveformSeek") } }

    @Test("A plain touch: a swipe of half the strip moves the fader half its range from Syndicate's level, and seeks nothing")
    func halfSwipe() throws {
        let rig = try C.started()
        Self.volume(rig, 0.25)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 8192)
        let sent = Self.sentVolumes(rig)
        #expect(abs((sent.last ?? 0) - 0.75) < 0.001, "sent \(sent)")
        #expect(Self.seeks(rig).isEmpty)
    }

    @Test("Shift + the strip seeks (needle drop), and moves no fader")
    func withShiftSeeks() throws {
        let rig = try C.started()
        Self.volume(rig, 0.25)
        Self.shift(rig, true)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 8192)
        #expect(Self.sentVolumes(rig).isEmpty)
        #expect(!Self.seeks(rig).isEmpty)
    }

    @Test("A touch with no travel sends nothing, even when the strip repeats where the finger is")
    func noTravel() throws {
        let rig = try C.started()
        Self.volume(rig, 0.25)
        Self.touch(rig, true)
        Self.at(rig, 4000)
        Self.at(rig, 4000)
        Self.touch(rig, false)
        #expect(Self.sentVolumes(rig).isEmpty)
        #expect(Self.seeks(rig).isEmpty)
    }

    @Test("Clamped at both ends, and travel past an end isn't stored up: coming back moves the fader at once")
    func clamped() throws {
        let rig = try C.started()
        Self.volume(rig, 0.75)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 8192)    // +0.5 from 0.75: past the top
        Self.at(rig, 12288)   // further past it
        Self.at(rig, 8192)    // back by a quarter: from the top, not from where the finger went
        let sent = Self.sentVolumes(rig)
        #expect(sent.count == 2 && sent[0] == 1.0 && abs(sent[1] - 0.75) < 0.001, "sent \(sent)")
        Self.at(rig, 0)
        Self.at(rig, 0)
        #expect(abs((Self.sentVolumes(rig).last ?? -1) - 0.25) < 0.001)
    }

    @Test("The layer is fixed at touch-down: Shift pressed mid-touch stays a fader move, with no track jump under the finger")
    func shiftPressedMidFaderTouch() throws {
        let rig = try C.started()
        Self.volume(rig, 0.25)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.shift(rig, true)
        Self.at(rig, 4096)
        Self.touch(rig, false)
        #expect(Self.sentVolumes(rig).count == 1)
        #expect(Self.seeks(rig).isEmpty)
    }

    @Test("The layer is fixed at touch-down: Shift let go mid-touch leaves the touch a seek, and moves no fader")
    func shiftLetGoMidSeek() throws {
        let rig = try C.started()
        Self.volume(rig, 0.25)
        Self.shift(rig, true)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.shift(rig, false)
        Self.at(rig, 4096)
        #expect(Self.sentVolumes(rig).isEmpty)
        #expect(Self.seeks(rig).count == 2)
    }

    @Test("With no Volume from Syndicate the touch does nothing: no fader move, no seek")
    func unknownLevel() throws {
        let rig = try C.started()
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 8192)
        #expect(Self.sentVolumes(rig).isEmpty)
        #expect(Self.seeks(rig).isEmpty)
    }

    @Test("With no Volume from Syndicate, the next touch counts from the level the last one sent")
    func fromLastSent() throws {
        let rig = try C.started()
        // Known once (a Resend), then the Volume box goes off: nothing more comes back.
        Self.volume(rig, 0.25)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 4096)    // to 0.5
        Self.touch(rig, false)
        Self.touch(rig, true)
        Self.at(rig, 8192)
        Self.at(rig, 12288)   // a quarter more: 0.75
        let sent = Self.sentVolumes(rig)
        #expect(abs((sent.last ?? 0) - 0.75) < 0.001, "sent \(sent)")
    }

    @Test("Another deck layer moves that deck's channel, from that channel's own level")
    func layerChange() throws {
        let rig = try C.started()
        Self.volume(rig, channel: 1, 0.25)
        Self.volume(rig, channel: 2, 0.5)
        rig.coordinator.setDeck(2, controller: 0)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 4096)
        let sent = Self.sentVolumes(rig, channel: 2)
        #expect(abs((sent.last ?? 0) - 0.75) < 0.001, "sent \(sent)")
        #expect(Self.sentVolumes(rig, channel: 1).isEmpty)
    }

    @Test("During a touch Syndicate's echoes are ignored, a late one too: the fader goes by the travel, and can't fight itself")
    func echoesIgnored() throws {
        let rig = try C.started()
        Self.volume(rig, 0.25)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 2048)        // to 0.375
        Self.at(rig, 4096)        // to 0.5
        Self.volume(rig, 0.375)   // the echo of the first, arriving late
        Self.at(rig, 6144)        // to 0.625, not 0.375 + an eighth
        Self.touch(rig, false)
        Self.touch(rig, true)
        Self.at(rig, 6144)
        Self.at(rig, 8192)        // the next touch starts where this one left it: 0.75
        let sent = Self.sentVolumes(rig)
        #expect(sent.count == 4, "sent \(sent)")
        #expect(abs(sent[2] - 0.625) < 0.001 && abs(sent[3] - 0.75) < 0.001, "sent \(sent)")
    }

    static let jump = #"{ "needle": { "shift_fader_mode": "jump" } }"#

    @Test("Jump: touching the strip's midpoint sets the fader to half, with no travel and no level from Syndicate")
    func jumpMidpoint() throws {
        let rig = try C.started(Self.jump)
        Self.touch(rig, true)
        Self.at(rig, 8192)
        #expect(Self.sentVolumes(rig).count == 1 && abs((Self.sentVolumes(rig).first ?? 0) - 0.5) < 0.001, "sent \(Self.sentVolumes(rig))")
        Self.at(rig, 16383)   // and follows the finger: the top is the fader's top
        Self.at(rig, 0)
        #expect(Self.sentVolumes(rig).suffix(2) == [1.0, 0.0])
        #expect(Self.seeks(rig).isEmpty)
    }

    @Test("needle.shift_fader false: Shift + the strip seeks as it always has, and moves no fader")
    func off() throws {
        let rig = try C.started(#"{ "needle": { "shift_fader": false } }"#)
        Self.volume(rig, 0.25)
        Self.shift(rig, true)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 8192)
        #expect(Self.sentVolumes(rig).isEmpty)
        #expect(!Self.seeks(rig).isEmpty)
    }

    @Test("Relative needs Syndicate's Volume, so the health check asks for it; off, or in jump, it isn't asked for")
    func volumeSubscription() throws {
        #expect(try C.started().coordinator.status.requiredSubscriptions.contains(.mixerVolume))
        #expect(try !C.started(#"{ "needle": { "shift_fader": false } }"#).coordinator.status.requiredSubscriptions.contains(.mixerVolume))
        #expect(try !C.started(Self.jump).coordinator.status.requiredSubscriptions.contains(.mixerVolume))
    }

    @Test("Settings' choice of jump applies from the next touch, with no relaunch; a touch already down keeps its mode")
    func settingNextTouch() throws {
        let rig = try C.started()
        Self.volume(rig, 0.25)
        Self.touch(rig, true)
        Self.at(rig, 0)
        rig.coordinator.apply(.setStripFader(StripFaderSetting(mode: .jump)))
        Self.at(rig, 4096)                    // still relative: 0.25 + a quarter
        #expect(abs((Self.sentVolumes(rig).last ?? 0) - 0.5) < 0.001)
        Self.touch(rig, false)
        rig.osc.sent.removeAll()
        Self.touch(rig, true)
        Self.at(rig, 16383)                   // jump: straight to the top, no travel
        #expect(Self.sentVolumes(rig) == [1.0])
        #expect(!rig.coordinator.status.requiredSubscriptions.contains(.mixerVolume))
    }

    @Test("Settings' off: Shift + the strip seeks, whatever the profile says, and Volume isn't asked for")
    func settingOff() throws {
        let rig = try C.started()
        rig.coordinator.apply(.setStripFader(StripFaderSetting(enabled: false)))
        Self.volume(rig, 0.25)
        Self.shift(rig, true)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 8192)
        #expect(Self.sentVolumes(rig).isEmpty)
        #expect(!Self.seeks(rig).isEmpty)
        #expect(!rig.coordinator.status.requiredSubscriptions.contains(.mixerVolume))
    }

    @Test("Settings shows the profile's choice until the DJ makes one, and nothing for a strip without a touch note")
    func shown() throws {
        let needle = try #require(try Mapping.bundledDefault().needle)
        #expect(StripFaderSetting().shown(for: needle) == .init(enabled: true, mode: .relative))
        #expect(StripFaderSetting(enabled: false).shown(for: needle) == .init(enabled: false, mode: .relative))
        #expect(StripFaderSetting(mode: .jump).shown(for: needle) == .init(enabled: true, mode: .jump))
        var untouched = needle
        untouched.requireTouch = false
        #expect(StripFaderSetting().shown(for: untouched) == nil)
        #expect(StripFaderSetting().shown(for: nil) == nil)
    }

    @Test("A fader touch ends with everything released (sleep, unplug): the next Shift touch seeks and moves no fader")
    func releasedEndsTouch() throws {
        let rig = try C.started()
        Self.volume(rig, 0.25)
        Self.touch(rig, true)
        Self.at(rig, 0)
        rig.coordinator.willSleep()   // no touch-up ever comes
        Self.shift(rig, true)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 8192)
        #expect(Self.sentVolumes(rig).isEmpty)
        #expect(!Self.seeks(rig).isEmpty)
    }

    @Test("A lost touch-up doesn't keep the strip a fader: each touch-down picks the layer afresh")
    func lostTouchUp() throws {
        let rig = try C.started()
        Self.volume(rig, 0.25)
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.shift(rig, true)
        Self.touch(rig, true)         // the note-off went missing: a new touch-down, with Shift
        Self.at(rig, 0)
        Self.at(rig, 8192)
        #expect(Self.sentVolumes(rig).isEmpty)
        #expect(!Self.seeks(rig).isEmpty)
    }

    @Test("On the unit's layer 2 (its own channel), the strip moves channel 2 from channel 2's level; channel 1 gets nothing")
    func unitLayer() throws {
        let rig = try LayersTests.layered()
        Self.volume(rig, channel: 1, 0.25)
        Self.volume(rig, channel: 2, 0.5)
        let ch2: UInt8 = 1
        func cc(_ controller: UInt8, _ value: UInt8) {
            rig.coordinator.midi(.controlChange(channel: ch2, controller: controller, value: value), source: Rig.lc6000.id)
        }
        rig.coordinator.midi(.noteOn(channel: ch2, note: 70, velocity: 127), source: Rig.lc6000.id)   // touch
        cc(64, 0); cc(65, 0)
        cc(64, 32); cc(65, 0)    // 4096: a quarter of the strip
        let sent = Self.sentVolumes(rig, channel: 2)
        #expect(abs((sent.last ?? 0) - 0.75) < 0.001, "sent \(sent)")
        #expect(Self.sentVolumes(rig, channel: 1).isEmpty)
    }

    /// A touch with or without Shift, then half the strip: whether it moved the fader, and whether it seeked.
    static func slide(_ rig: Rig, shift: Bool) -> (faded: Bool, seeked: Bool) {
        rig.osc.sent.removeAll()
        if shift { Self.shift(rig, true) }
        Self.touch(rig, true)
        Self.at(rig, 0)
        Self.at(rig, 8192)
        Self.touch(rig, false)
        if shift { Self.shift(rig, false) }
        return (!Self.sentVolumes(rig).isEmpty, !Self.seeks(rig).isEmpty)
    }

    @Test("The fader off (the profile's or Settings'): the strip seeks with or without Shift, so needle drop is never lost")
    func offSeeksBothWays() throws {
        let profileOff = try C.started(#"{ "needle": { "shift_fader": false } }"#)
        let settingOff = try C.started()
        settingOff.coordinator.apply(.setStripFader(StripFaderSetting(enabled: false)))
        for rig in [profileOff, settingOff] {
            Self.volume(rig, 0.25)
            for shift in [false, true] {
                let slid = Self.slide(rig, shift: shift)
                #expect(!slid.faded && slid.seeked, "shift \(shift)")
            }
        }
    }
}
