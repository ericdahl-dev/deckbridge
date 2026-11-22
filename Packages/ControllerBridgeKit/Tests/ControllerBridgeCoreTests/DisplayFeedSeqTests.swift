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
}
