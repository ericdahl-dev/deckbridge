@testable import ControllerBridgeCore
import Testing

/// The display feed over the USB cable (#667), at the Coordinator: a second destination with its own switch, sent the
/// same feed as Wi-Fi. Its port opening is its destination opening, so the snapshot goes then, on that cable only.
@Suite("Display feed: the USB cable at the Coordinator")
struct DisplayFeedCableTests {
    typealias Feed = DisplayFeedCoordinatorTests

    /// A rig with both destinations attached, both switches off.
    static func rig() throws -> (Rig, wifi: Rig.FakeOSC, cable: Rig.FakeOSC) {
        let rig = try Rig()
        let wifi = Rig.FakeOSC(), cable = Rig.FakeOSC()
        rig.coordinator.attachDisplayFeed(wifi)
        rig.coordinator.attachCableFeed(cable)
        return (rig, wifi, cable)
    }

    static let cableOnly = DisplayFeedSettings(enabled: false, cable: true)

    @Test("Cable on with Wi-Fi off: the snapshot goes on the cable once its port opens, nothing on Wi-Fi")
    func cableOnSendsSnapshotOnTheCable() throws {
        let (rig, wifi, cable) = try Self.rig()
        rig.coordinator.start()
        Feed.load(rig)
        rig.coordinator.feedback(Feed.factoryPalette)
        rig.coordinator.setDisplayFeed(Self.cableOnly)
        #expect(cable.sent == [])
        rig.coordinator.cableFeedReady()
        #expect(cable.sent == Feed.snapshot(deck: 1, color: 0xFF0000, title: "Daybreak", artist: "Bill Hamel, Jeremus"))
        #expect(wifi.sent == [])
    }

    @Test("Unplugged and plugged back in: the port opening again sends the snapshot again")
    func replugSendsTheSnapshotAgain() throws {
        let (rig, _, cable) = try Self.rig()
        rig.coordinator.start()
        Feed.load(rig)
        rig.coordinator.feedback(Feed.factoryPalette)
        rig.coordinator.setDisplayFeed(Self.cableOnly)
        rig.coordinator.cableFeedReady()
        cable.sent = []
        rig.coordinator.cableFeedReady()
        #expect(cable.sent == Feed.snapshot(deck: 1, color: 0xFF0000, title: "Daybreak", artist: "Bill Hamel, Jeremus"))
    }

    @Test("The cable's switch off says goodbye on the cable only; Wi-Fi's feed goes on")
    func cableOffSaysGoodbyeOnTheCableOnly() throws {
        let (rig, wifi, cable) = try Self.rig()
        rig.coordinator.start()
        Feed.load(rig)
        rig.coordinator.feedback(Feed.factoryPalette)
        var both = Feed.on
        both.cable = true
        rig.coordinator.setDisplayFeed(both)
        rig.coordinator.displayFeedReady()
        rig.coordinator.cableFeedReady()
        wifi.sent = []
        cable.sent = []
        both.cable = false
        rig.coordinator.setDisplayFeed(both)
        #expect(cable.sent == [DisplayFeedGoodbyeTests.goodbye])
        #expect(!wifi.sent.contains(DisplayFeedGoodbyeTests.goodbye))
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)]))
        #expect(wifi.sent.contains(Feed.message("playing", Int32(1))))
        #expect(cable.sent == [DisplayFeedGoodbyeTests.goodbye])
    }

    @Test("The cable alone asks Syndicate for the meter and phase the feed reads")
    func cableAloneAsksForMeterAndPhase() throws {
        let (rig, _, _) = try Self.rig()
        rig.coordinator.setDisplayFeed(Self.cableOnly)
        #expect(rig.coordinator.status.requiredSubscriptions.contains(.mixerMeter))
        #expect(rig.coordinator.status.requiredSubscriptions.contains(.phaseOffset))
    }

    @Test("Quitting says goodbye on the cable too, last")
    func quitSaysGoodbyeOnTheCable() throws {
        let (rig, _, cable) = try Self.rig()
        rig.coordinator.start()
        Feed.load(rig)
        rig.coordinator.feedback(Feed.factoryPalette)
        rig.coordinator.setDisplayFeed(Self.cableOnly)
        rig.coordinator.cableFeedReady()
        rig.coordinator.quit()
        #expect(cable.bundles.last == [DisplayFeedGoodbyeTests.goodbye])
    }
}
