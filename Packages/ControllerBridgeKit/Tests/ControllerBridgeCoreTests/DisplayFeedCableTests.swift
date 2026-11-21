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

    /// Runs the Engine over `events` with the real rig, as DisplayFeedDemoTests does.
    static func run(_ rig: Rig, _ made: DisplayFeedDemoTests.Made, _ events: (EventPipe.Producer) -> Void) async {
        let pipe = EventPipe()
        events(pipe.producer)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, makeDemo: DisplayFeedDemoTests.demoMaker(rig, made)).run(pipe.events)
    }

    static func realRig() throws -> (Rig, wifi: Rig.FakeOSC, cable: Rig.FakeOSC) {
        let (rig, wifi, cable) = try Self.rig()
        rig.coordinator.start()
        Feed.load(rig)
        rig.coordinator.feedback(Feed.factoryPalette)
        return (rig, wifi, cable)
    }

    @Test("The demo takes the cable's feed while it runs: the demo deck goes on the cable")
    func demoTakesTheCable() async throws {
        let (rig, wifi, cable) = try Self.realRig()
        let made = DisplayFeedDemoTests.Made()
        await Self.run(rig, made) {
            $0.send(.setDisplayFeed(Self.cableOnly))
            $0.send(.cableFeedReady)
            $0.demo(on: true)
        }
        cable.sent.removeAll()
        let session = try #require(made.session)
        for step in 1...110 { rig.clock.now = Double(step) * 0.01; session.tick() }
        #expect(DisplayFeedDemoTests.text(cable, "title").first == "Demo Track")
        #expect(wifi.sent == [])
    }

    @Test("Demo off: the cable goes back to the real deck with a full snapshot, and the stopped demo sends nothing on it")
    func demoGivesTheCableBack() async throws {
        let (rig, _, cable) = try Self.realRig()
        let made = DisplayFeedDemoTests.Made()
        await Self.run(rig, made) {
            $0.send(.setDisplayFeed(Self.cableOnly))
            $0.send(.cableFeedReady)
            $0.demo(on: true)
            $0.demo(on: false)
        }
        let daybreak = Feed.snapshot(deck: 1, color: 0xFF0000, title: "Daybreak", artist: "Bill Hamel, Jeremus")
        #expect(cable.sent == daybreak + daybreak)
        cable.sent.removeAll()
        let session = try #require(made.session)
        for step in 1...300 { rig.clock.now = Double(step) * 0.01; session.tick() }
        #expect(cable.sent == [])
    }
}
