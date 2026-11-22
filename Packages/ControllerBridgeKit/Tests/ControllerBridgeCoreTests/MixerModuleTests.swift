import Foundation
@testable import ControllerBridgeCore
import Testing

/// The mixer section as its own module (#383, from #207, #320, #321): faders and knobs with pickup, cue/mute/solo,
/// and the meter. Plain values in, sends out; the Bridge addresses them to its channel and drives the LEDs.
@Suite("Mixer module")
struct MixerModuleTests {
    typealias Send = MixerModule.Send
    static func mixer() throws -> Mapping.Mixer { try #require(try Mapping.bundledDefault(overriddenBy: Data(MixerTests.section.utf8)).mixer) }

    @Test("A 7-bit fader at 64 is 0.5, sent once; a 14-bit knob sends when its LSB arrives, 8192 is 0.5; other CCs aren't the mixer's")
    func faders() throws {
        let mixer = try Self.mixer()
        var module = MixerModule()
        #expect(module.cc(19, value: 64, mixer: mixer, now: 0) == [.value(.volume, 0.5)])
        #expect(module.cc(19, value: 64, mixer: mixer, now: 0) == [])
        #expect(module.cc(7, value: 64, mixer: mixer, now: 0) == [])
        #expect(module.cc(39, value: 0, mixer: mixer, now: 0) == [.value(.eqHigh, 0.5)])
        #expect(module.cc(99, value: 1, mixer: mixer, now: 0) == nil)
    }

    @Test("Moved from outside, the fader waits to meet it, within 0.03 or across it; its own echo doesn't arm it")
    func pickup() throws {
        let mixer = try Self.mixer()
        var module = MixerModule()
        _ = module.cc(19, value: 64, mixer: mixer, now: 0)
        _ = module.feedback(.volume, 0.5, mixer: mixer, now: 0.1)          // the echo
        #expect(module.cc(19, value: 0, mixer: mixer, now: 1) == [.value(.volume, 0)])
        _ = module.feedback(.volume, 0.8, mixer: mixer, now: 2)            // the mouse
        #expect(module.cc(19, value: 70, mixer: mixer, now: 3) == [])
        #expect(module.cc(19, value: 127, mixer: mixer, now: 3) == [.value(.volume, 1)])
    }

    @Test("Mute sends the opposite of what Syndicate reported; its LED follows the report")
    func buttons() throws {
        let mixer = try Self.mixer()
        var module = MixerModule()
        #expect(module.note(85, pressed: true, mixer: mixer) == [.button(.mute, 1)])
        #expect(module.note(85, pressed: false, mixer: mixer) == [])
        #expect(module.feedback(.mute, 1, mixer: mixer, now: 0) == [.buttonLEDs])
        #expect(module.buttonLEDs(mixer: mixer).filter(\.on).map(\.note) == [85])
        #expect(module.note(85, pressed: true, mixer: mixer) == [.button(.mute, 0)])
        #expect(module.note(1, pressed: true, mixer: mixer) == nil)
    }

    @Test("The meter: at most 30 a second, the peak held 300 ms, above 1.0 the clip value")
    func meter() throws {
        let mixer = try Self.mixer()
        var module = MixerModule()
        _ = module.feedback(.meter, 0.6, mixer: mixer, now: 0)
        #expect(module.meterTick(mixer: mixer, now: 0) == 64)              // 0.6 of 7 steps up: index 4
        module.meterShown(64, now: 0)
        _ = module.feedback(.meter, 0.1, mixer: mixer, now: 0.01)
        #expect(module.meterTick(mixer: mixer, now: 0.02) == nil, "under 1/30 s")
        #expect(module.meterTick(mixer: mixer, now: 0.05) == nil, "the peak holds, the same value")
        #expect(module.meterTick(mixer: mixer, now: 0.31) == 0)
        _ = module.feedback(.meter, 1.2, mixer: mixer, now: 0.4)
        #expect(module.meterTick(mixer: mixer, now: 0.4) == 127)
    }

    @Test("Another channel forgets the old reports and waits for the new ones for the answer window")
    func forgetChannel() throws {
        let mixer = try Self.mixer()
        var module = MixerModule()
        _ = module.feedback(.mute, 1, mixer: mixer, now: 0)
        module.forgetChannel(mixer: mixer, now: 10, answerWindow: 2)
        #expect(module.buttonLEDs(mixer: mixer).allSatisfy { !$0.on })
        #expect(module.cc(19, value: 64, mixer: mixer, now: 11) == [])
        #expect(module.cc(19, value: 64, mixer: mixer, now: 12) == [.value(.volume, 0.5)])
    }
}
