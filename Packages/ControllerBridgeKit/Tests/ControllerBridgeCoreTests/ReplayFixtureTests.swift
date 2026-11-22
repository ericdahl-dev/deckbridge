import Foundation
import ControllerBridgeCore
import Testing

/// Replays every capture fixture in Resources/Fixtures (#189) against the bundled profile it names, at the Coordinator
/// seam: each step's MIDI in order, and where the fixture says, exactly the OSC Syndicate should get. The draft tool
/// writes a fixture with each new profile, so it has tests from day one.
@Suite("Capture fixture replay")
struct ReplayFixtureTests {
    struct Fixture: Decodable {
        struct Step: Decodable { var prompt: String; var midi: [String]; var expect: [String]? }
        var profile: String
        var steps: [Step]
    }

    /// Found through Bundle's own lookup, as ProfileTests finds test-pad.json: the resource bundle's layout differs
    /// between a local build and CI, so a path built from resourceURL found nothing there.
    static let fixtures: [URL] = (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Resources/Fixtures") ?? [])
        .sorted { $0.path < $1.path }

    static func event(_ hex: String) -> MIDIEvent? {
        let b = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard b.count == 3 else { return nil }
        let channel = b[0] & 0x0F
        switch b[0] & 0xF0 {
        case 0x90: return .noteOn(channel: channel, note: b[1], velocity: b[2])
        case 0x80: return .noteOff(channel: channel, note: b[1], velocity: b[2])
        case 0xB0: return .controlChange(channel: channel, controller: b[1], value: b[2])
        default: return nil
        }
    }

    static func text(_ message: OSCMessage) -> String {
        let address = message.address.replacingOccurrences(of: "/Syndicate/", with: "")
        let args = message.arguments.map { argument -> String in
            switch argument {
            case .int(let n): String(n)
            case .float(let f): String(f)
            case .string(let s): s
            }
        }
        return ([address] + args).joined(separator: " ")
    }

    @Test("There's at least the LC6000's fixture")
    func found() {
        #expect(Self.fixtures.map(\.lastPathComponent).contains("denon-lc6000-prime.json"))
    }

    @Test("Each fixture's steps send exactly the OSC they expect, in order", arguments: fixtures)
    func replay(_ url: URL) throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let profile = try #require(try ControllerProfile.bundled().first { $0.id == fixture.profile })
        let rig = try Rig()
        rig.coordinator.setProfiles([profile])
        rig.coordinator.start()
        rig.coordinator.setControllers(ControllerSettings.expanded(
            [ControllerSettings(deck: 1, input: Rig.lc6000, output: Rig.lc6000Out)], layers: profile.mapping.midi.layers
        ))
        for step in fixture.steps {
            rig.osc.sent.removeAll()
            for hex in step.midi {
                if let event = Self.event(hex) { rig.coordinator.midi(event, source: Rig.lc6000.id) }
            }
            rig.clock.now += 1
            rig.coordinator.tick()
            if let expect = step.expect {
                // The bridge's own Resend (no Syndicate answers here) isn't the step's doing.
                let sent = rig.osc.sent.filter { !$0.address.hasSuffix("/Feedback/Resend") }
                #expect(sent.map(Self.text) == expect, "\(fixture.profile) \(step.prompt)")
            }
        }
    }
}
