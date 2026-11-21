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
}
