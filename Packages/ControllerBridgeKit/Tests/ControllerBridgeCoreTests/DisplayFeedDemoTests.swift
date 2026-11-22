import Foundation
@testable import ControllerBridgeCore
import Synchronization
import Testing

/// The display feed during the demo (#625, #490 story 24): the Engine swaps in the demo's own Coordinator, and the
/// feed goes with it. The feed's fake port is attached to the real Coordinator, as the app attaches it.
@Suite("Display feed: the demo")
struct DisplayFeedDemoTests {
    /// Keeps the session the Engine makes, so a test can drive it after the pipe ends.
    final class Made: @unchecked Sendable {
        var session: DemoSession?
    }

    /// Set from the Engine's task when its status first reports the demo: the test's barrier, under a lock.
    final class DemoReported: Sendable {
        let on = Mutex(false)
    }

    /// The Engine run beside the test. The test touches the Coordinators only while the Engine waits on the pipe
    /// (after `waitFor`) or after it returns, so handing it to the task is safe.
    final class Running: @unchecked Sendable {
        let engine: Engine, events: AsyncStream<PipeEvent>
        init(engine: Engine, events: AsyncStream<PipeEvent>) { self.engine = engine; self.events = events }
        func run() async { await engine.run(events) }
    }

    /// The status reports the demo once its event is done: the Engine then waits on the pipe. Bounded, so a
    /// regression fails here instead of hanging.
    static func waitFor(_ reported: DemoReported) async throws {
        for _ in 0..<100_000 {
            if reported.on.withLock({ $0 }) { return }
            await Task.yield()
        }
        Issue.record("The Engine never reported the demo")
        throw CancellationError()
    }

    static func demoMaker(_ rig: Rig, _ made: Made) -> @Sendable (ControllerProfile) -> DemoSession {
        let clock = rig.clock, log = rig.log
        return { profile in
            let session = DemoSession(profile: profile, clock: clock, log: log, ledOutput: Rig.FakeOutput())
            made.session = session
            return session
        }
    }

    /// The real deck in front, known: Syndicate's palette, deck 1 loaded with Daybreak, and the feed on.
    static func realRig() throws -> (Rig, Rig.FakeOSC) {
        let (rig, feed) = try DisplayFeedCoordinatorTests.rig()
        rig.coordinator.start()
        DisplayFeedCoordinatorTests.load(rig)
        rig.coordinator.feedback(DisplayFeedCoordinatorTests.factoryPalette)
        return (rig, feed)
    }

    static func run(_ rig: Rig, _ made: Made, _ events: (EventPipe.Producer) -> Void) async {
        let pipe = EventPipe()
        events(pipe.producer)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log, makeDemo: demoMaker(rig, made)).run(pipe.events)
    }

    static func text(_ feed: Rig.FakeOSC, _ name: String) -> [String] {
        feed.sent.filter { $0.address == "/DeckBridge/Display/" + name }.compactMap {
            if case .string(let value)? = $0.arguments.first { return value }
            return nil
        }
    }

    @Test("Demo on with the feed on: the demo deck's full snapshot goes out (after the hold, its Syndicate sends no palette)")
    func demoOn() async throws {
        let (rig, feed) = try Self.realRig()
        let made = Made()
        await Self.run(rig, made) {
            $0.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
            $0.send(.displayFeedReady)
            $0.demo(on: true)
        }
        feed.sent.removeAll()
        let session = try #require(made.session)
        for step in 1...110 {
            rig.clock.now = Double(step) * 0.01
            session.tick()
        }
        #expect(Self.text(feed, "title").first == "Demo Track")
        #expect(Self.text(feed, "artist").first == "DeckBridge")
        #expect(Self.text(feed, "key").first == "Am")
        #expect(feed.sent.filter { $0.address.hasSuffix("/deck") }.count == 1)
    }

    @Test("As the demo plays, the feed follows it, changes only: the master beat moves, the track isn't sent again")
    func demoPlays() async throws {
        let (rig, feed) = try Self.realRig()
        let made = Made()
        await Self.run(rig, made) {
            $0.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
            $0.send(.displayFeedReady)
            $0.demo(on: true)
        }
        let session = try #require(made.session)
        for step in 1...110 { rig.clock.now = Double(step) * 0.01; session.tick() }
        feed.sent.removeAll()
        // Under the 2 s keepalive, so only changes.
        for step in 111...190 { rig.clock.now = Double(step) * 0.01; session.tick() }
        let beats = feed.sent.filter { $0.address.hasSuffix("/beat") }
        // The demo plays from 0.5 s, a beat every 0.5 s: the one at 1.5 s falls here.
        #expect(beats.count == 1)
        #expect(Self.text(feed, "title").isEmpty)
    }

    @Test("Demo off: the feed goes back to the real deck in front with a full snapshot, and the stopped demo sends nothing")
    func demoOff() async throws {
        let (rig, feed) = try Self.realRig()
        let made = Made()
        await Self.run(rig, made) {
            $0.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
            $0.send(.displayFeedReady)
            $0.demo(on: true)
            $0.demo(on: false)
        }
        let daybreak = DisplayFeedCoordinatorTests.snapshot(deck: 1, color: 0xFF0000, title: "Daybreak", artist: "Bill Hamel, Jeremus")
        // Turned on, then back from the demo (whose own snapshot was still held).
        #expect(feed.sent == daybreak + daybreak)
        feed.sent.removeAll()
        let session = try #require(made.session)
        for step in 1...300 { rig.clock.now = Double(step) * 0.01; session.tick() }
        #expect(feed.sent == [])
    }

    @Test("The destination opening again during the demo (a wake): the demo's Coordinator sends the full snapshot again, not the real one")
    func readyDuringDemo() async throws {
        let (rig, feed) = try Self.realRig()
        let made = Made(), demoReported = DemoReported()
        let pipe = EventPipe()
        let engine = Engine(coordinator: rig.coordinator, log: rig.log, onStatus: { status in
            if status.demo { demoReported.on.withLock { $0 = true } }
        }, makeDemo: Self.demoMaker(rig, made))
        let box = Running(engine: engine, events: pipe.events)
        let running = Task { await box.run() }
        pipe.producer.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
        pipe.producer.send(.displayFeedReady)
        pipe.producer.demo(on: true)
        try await Self.waitFor(demoReported)
        let session = try #require(made.session)
        for step in 1...110 { rig.clock.now = Double(step) * 0.01; session.tick() }
        #expect(Self.text(feed, "title").last == "Demo Track")
        feed.sent.removeAll()
        pipe.producer.send(.displayFeedReady)
        pipe.producer.finish()
        await running.value
        // Its snapshot waits the hold again (the demo's Syndicate sends no palette), well before the 2 s keepalive.
        for step in 111...225 { rig.clock.now = Double(step) * 0.01; session.tick() }
        #expect(Self.text(feed, "title") == ["Demo Track"])
        #expect(!Self.text(feed, "title").contains("Daybreak"))
    }

    @Test("The feed turned off in Settings during the demo waits for its end, like every setting, and then holds: nothing goes out after")
    func turnedOffDuringDemo() async throws {
        let (rig, feed) = try Self.realRig()
        let made = Made()
        var off = DisplayFeedCoordinatorTests.on
        off.enabled = false
        await Self.run(rig, made) {
            $0.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
            $0.send(.displayFeedReady)
            $0.demo(on: true)
            $0.send(.setDisplayFeed(off))
            $0.demo(on: false)
        }
        let daybreak = DisplayFeedCoordinatorTests.snapshot(deck: 1, color: 0xFF0000, title: "Daybreak", artist: "Bill Hamel, Jeremus")
        #expect(feed.sent == daybreak)
        feed.sent.removeAll()
        for step in 1...300 { rig.clock.now = Double(step) * 0.01; rig.coordinator.tick() }
        #expect(feed.sent == [])
    }

    @Test("Demo on sends nothing of the real controller's: stopping it (layer 2's empty deck in front, deck 1 loaded) doesn't put deck 1 on the panel")
    func demoOnSendsNoStrayDeck() async throws {
        let (rig, feed) = try DisplayFeedCoordinatorTests.rig()
        DisplayFeedCoordinatorTests.layered(rig)
        DisplayFeedCoordinatorTests.load(rig, deck: 1)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/2/Loaded", [.int(0)]))
        LayersTests.switchLayer(rig, from: 1, to: 2)
        rig.coordinator.feedback(DisplayFeedCoordinatorTests.factoryPalette)
        let made = Made()
        await Self.run(rig, made) {
            $0.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
            $0.send(.displayFeedReady)
            $0.demo(on: true)
        }
        #expect(feed.sent == DisplayFeedCoordinatorTests.snapshot(deck: 2, color: 0xFFFF00))
    }

    @Test("During the demo the real Coordinator sends nothing: the preview's deck (sent to both) moves only the demo's")
    func realSilentDuringDemo() async throws {
        // No controller connected, so the real deck in front follows the preview's deck.
        let (rig, feed) = try DisplayFeedCoordinatorTests.rig()
        DisplayFeedCoordinatorTests.layered(rig)
        rig.midi.sources.removeAll { $0.id == Rig.lc6000.id }
        rig.coordinator.devicesChanged()
        DisplayFeedCoordinatorTests.load(rig, deck: 1)
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/3/Loaded", [.int(0)]))
        rig.coordinator.feedback(DisplayFeedCoordinatorTests.factoryPalette)
        let made = Made()
        await Self.run(rig, made) {
            $0.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
            $0.send(.displayFeedReady)
            $0.demo(on: true)
            $0.send(.setJogPreviewDeck(3))
        }
        #expect(!feed.sent.contains(OSCMessage("/DeckBridge/Display/deck", [.int(3)])))
    }

    @Test("Demo off after the demo has run a while: the real deck's full snapshot goes out at once, then only changes")
    func demoOffAfterRunning() async throws {
        let (rig, feed) = try Self.realRig()
        let made = Made(), demoReported = DemoReported()
        let pipe = EventPipe()
        let engine = Engine(coordinator: rig.coordinator, log: rig.log, onStatus: { status in
            if status.demo { demoReported.on.withLock { $0 = true } }
        }, makeDemo: Self.demoMaker(rig, made))
        let box = Running(engine: engine, events: pipe.events)
        let running = Task { await box.run() }
        pipe.producer.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
        pipe.producer.send(.displayFeedReady)
        pipe.producer.demo(on: true)
        try await Self.waitFor(demoReported)
        let session = try #require(made.session)
        for step in 1...250 { rig.clock.now = Double(step) * 0.01; session.tick() }
        #expect(Self.text(feed, "title").last == "Demo Track")
        feed.sent.removeAll()
        pipe.producer.demo(on: false)
        pipe.producer.finish()
        await running.value
        let daybreak = DisplayFeedCoordinatorTests.snapshot(deck: 1, color: 0xFF0000, title: "Daybreak", artist: "Bill Hamel, Jeremus")
        #expect(feed.sent == daybreak)
        feed.sent.removeAll()
        // Under the next keepalive: nothing changed on the real deck.
        for step in 251...400 { rig.clock.now = Double(step) * 0.01; rig.coordinator.tick() }
        #expect(feed.sent == [])
    }
}
