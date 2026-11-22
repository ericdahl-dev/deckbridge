import Foundation
@testable import ControllerBridgeCore
import Testing

/// The display feed in the Debug trace (#636): enough to tell, afterwards, what reached the address set: the setting,
/// the destination opening, each full snapshot as one line, the hold. Nothing per fast field.
@Suite("Display feed: the Debug trace")
struct DisplayFeedTraceTests {
    static func traced() throws -> (Rig, TraceCoordinatorTests.Lines) {
        let (rig, _) = try DisplayFeedCoordinatorTests.rig()
        let lines = TraceCoordinatorTests.Lines()
        rig.coordinator.trace = { category, text in lines.list.append((category, text)) }
        rig.coordinator.start()
        return (rig, lines)
    }

    @Test("Turned on: the setting, the destination opening and the opening snapshot, one line each")
    func turnedOn() throws {
        let (rig, lines) = try Self.traced()
        DisplayFeedCoordinatorTests.load(rig)
        DisplayFeedCoordinatorTests.turnOn(rig)
        #expect(lines.of(.displayFeed) == [
            "on: 192.168.1.40:9100, waiting for its destination",
            "destination open",
            #"snapshot (destination open): deck 1, loaded 1, "Daybreak", clockBpm 0, 21 messages in 1 bundle"#,
        ])
    }

    @Test("Keepalives are one line each; a second of Position (progress, the times) adds none; turned off is one line")
    func keepaliveAndFastFields() throws {
        let (rig, lines) = try Self.traced()
        DisplayFeedCoordinatorTests.load(rig)
        DisplayFeedCoordinatorTests.turnOn(rig)
        lines.list.removeAll()
        for step in 1...200 {
            rig.clock.now = Double(step) * 0.01
            MainCueTests.position(rig, Float(step) / 10)
            rig.coordinator.tick()
        }
        #expect(lines.of(.displayFeed) == [#"snapshot (keepalive): deck 1, loaded 1, "Daybreak", clockBpm 0, 21 messages in 1 bundle"#])
        lines.list.removeAll()
        var off = DisplayFeedCoordinatorTests.on
        off.enabled = false
        rig.coordinator.setDisplayFeed(off)
        #expect(lines.of(.displayFeed) == ["off", "goodbye"])
    }

    @Test("A snapshot's line says the clockBpm it sent, so a trace shows what a display times its beats by (#674)")
    func clockBpm() throws {
        let (rig, lines) = try Self.traced()
        DisplayFeedCoordinatorTests.load(rig)
        DisplayFeedCoordinatorTests.turnOn(rig)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Header/BPM", [.float(127.5)]))
        lines.list.removeAll()
        for step in 1...4 {
            rig.clock.now = Double(step) * 0.5
            rig.coordinator.feedback(OSCMessage("/Syndicate/Header/Clock", [.int(Int32(step))]))
        }
        #expect(lines.of(.displayFeed) == [#"snapshot (keepalive): deck 1, loaded 1, "Daybreak", clockBpm 127.5, 21 messages in 1 bundle"#])
    }

    @Test("The hold, and an empty deck's snapshot: what the panel was told is in the line")
    func holdAndEmpty() throws {
        let (rig, lines) = try Self.traced()
        DisplayFeedCoordinatorTests.turnOn(rig, heard: false)
        rig.clock.now = 1
        rig.coordinator.tick()
        #expect(lines.of(.displayFeed) == [
            "on: 192.168.1.40:9100, waiting for its destination",
            "destination open",
            "holding the first snapshot until Syndicate answers for deck 1, at most 1 s",
            #"snapshot (no answer from Syndicate in 1 s): deck 1, loaded 0, "", clockBpm 0, 21 messages in 1 bundle"#,
        ])
    }

    @Test("Another deck in front is its own snapshot line")
    func deckChange() throws {
        let (rig, lines) = try Self.traced()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Loaded", [.int(0)]))
        DisplayFeedCoordinatorTests.turnOn(rig)
        lines.list.removeAll()
        rig.coordinator.setDeck(2, controller: 0)
        #expect(lines.of(.displayFeed) == [#"snapshot (deck 2 in front): deck 2, loaded 0, "", clockBpm 0, 21 messages in 1 bundle"#])
    }
}
