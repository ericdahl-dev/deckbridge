import Foundation
@testable import ControllerBridgeCore
import Testing

/// The feed's sequence number (#750): every bundle starts with `/DeckBridge/Display/seq`, an int counting the bundles
/// sent to this destination, so a display can count the datagrams it never got. A display that doesn't know the
/// address ignores it (ADR 0011).
@Suite("Display feed: the sequence number")
struct DisplayFeedSeqTests {
    @Test("Every bundle starts with seq, counting from 1: the snapshot, the changes and the goodbye")
    func counts() throws {
        let (rig, feed) = try DisplayFeedCoordinatorTests.rig()
        rig.coordinator.start()
        DisplayFeedCoordinatorTests.load(rig)
        DisplayFeedCoordinatorTests.turnOn(rig)
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(title: "Nightfall"))
        DisplayFeedCoordinatorTests.run(rig, from: 0.01, to: 1)
        rig.coordinator.quit()
        #expect(feed.rawBundles.count >= 3)
        #expect(feed.rawBundles.allSatisfy { $0.first?.address == "/DeckBridge/Display/seq" })
        #expect(feed.seqs == (1...UInt32(feed.rawBundles.count)).map { $0 })
    }

    @Test("It starts again at 1 each time the destination opens: off and on, or a new address")
    func restartsOnOpen() throws {
        let (rig, feed) = try DisplayFeedCoordinatorTests.rig()
        rig.coordinator.start()
        DisplayFeedCoordinatorTests.load(rig)
        DisplayFeedCoordinatorTests.turnOn(rig)
        DisplayFeedCoordinatorTests.run(rig, from: 0.01, to: 1)
        var off = DisplayFeedCoordinatorTests.on
        off.enabled = false
        rig.coordinator.setDisplayFeed(off)
        #expect(feed.seqs.count >= 2)
        let before = feed.seqs.count

        DisplayFeedCoordinatorTests.turnOn(rig)
        #expect(feed.seqs.dropFirst(before).first == 1)

        let moved = feed.seqs.count
        var elsewhere = DisplayFeedCoordinatorTests.on
        elsewhere.host = "192.168.1.41"
        DisplayFeedCoordinatorTests.turnOn(rig, elsewhere)
        #expect(feed.seqs.dropFirst(moved).first == 1)
    }

    @Test("Numbered, a bundle is still at most 1200 bytes: the split leaves room for the seq")
    func ceiling() {
        // Many small messages, so the split fills bundles to within a message of the ceiling.
        let messages = (0..<400).map { OSCMessage("/DeckBridge/Display/title", [.string(String(repeating: "x", count: $0 % 23))]) }
        let bundles = DisplayFeed.bundles(messages)
        #expect(bundles.count > 1)
        #expect(bundles.allSatisfy { OSCPacket.bundle([DisplayFeed.seq(.max)] + $0).count <= DisplayFeed.bundleCeiling })
        #expect(bundles.flatMap { $0 } == messages)
    }
}
