import Foundation
@testable import ControllerBridgeCore
import Testing

/// The display feed's goodbye (#651): when DeckBridge quits or the feed is turned off, the last datagram tells the
/// display to show its own idle look. `/DeckBridge/Display/goodbye ,i 1`, as a one-message bundle; agreed with the
/// panel's side. Only once the destination has opened: a display that never heard from us needs no goodbye.
@Suite("Display feed: the goodbye")
struct DisplayFeedGoodbyeTests {
    static let goodbye = OSCMessage("/DeckBridge/Display/goodbye", [.int(1)])

    static func onAndLoaded() throws -> (Rig, Rig.FakeOSC) {
        let (rig, feed) = try DisplayFeedCoordinatorTests.rig()
        rig.coordinator.start()
        DisplayFeedCoordinatorTests.load(rig)
        DisplayFeedCoordinatorTests.turnOn(rig)
        return (rig, feed)
    }

    @Test("Quitting sends the goodbye as the last datagram, a bundle of its own")
    func quit() throws {
        let (rig, feed) = try Self.onAndLoaded()
        rig.coordinator.quit()
        #expect(feed.bundles.last == [Self.goodbye])
        #expect(feed.sent.last == Self.goodbye)
        #expect(feed.sent.filter { $0 == Self.goodbye }.count == 1)
    }

    @Test("Turning the feed off sends the goodbye, and nothing goes out after it")
    func turnedOff() throws {
        let (rig, feed) = try Self.onAndLoaded()
        feed.sent.removeAll()
        var off = DisplayFeedCoordinatorTests.on
        off.enabled = false
        rig.coordinator.setDisplayFeed(off)
        #expect(feed.sent == [Self.goodbye])
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(title: "Nightfall"))
        DisplayFeedCoordinatorTests.run(rig, from: 0.01, to: 3)
        rig.coordinator.quit()
        #expect(feed.sent == [Self.goodbye])
    }

    @Test("A feed whose destination never opened has no one to say goodbye to: nothing on off or quit")
    func neverOpened() throws {
        let (rig, feed) = try DisplayFeedCoordinatorTests.rig()
        rig.coordinator.start()
        rig.coordinator.setDisplayFeed(DisplayFeedCoordinatorTests.on)
        var off = DisplayFeedCoordinatorTests.on
        off.enabled = false
        rig.coordinator.setDisplayFeed(off)
        rig.coordinator.quit()
        #expect(feed.sent == [])
    }

    @Test("The demo's hand-over, on and off, says no goodbye: the display keeps showing a deck")
    func demoHandOver() async throws {
        let (rig, feed) = try DisplayFeedDemoTests.realRig()
        let made = DisplayFeedDemoTests.Made()
        await DisplayFeedDemoTests.run(rig, made) {
            $0.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
            $0.send(.displayFeedReady)
            $0.demo(on: true)
            $0.demo(on: false)
        }
        #expect(!feed.sent.contains(Self.goodbye))
    }

    @Test("Quitting during the demo: the demo's Coordinator, which holds the feed, says the goodbye last")
    func quitDuringDemo() async throws {
        let (rig, feed) = try DisplayFeedDemoTests.realRig()
        let made = DisplayFeedDemoTests.Made()
        await DisplayFeedDemoTests.run(rig, made) {
            $0.send(.setDisplayFeed(DisplayFeedCoordinatorTests.on))
            $0.send(.displayFeedReady)
            $0.demo(on: true)
            $0.stop()
        }
        #expect(feed.sent.last == Self.goodbye)
        #expect(feed.sent.filter { $0 == Self.goodbye }.count == 1)
    }

    @Test("The queue's flush waits until every send has gone to the destination (the goodbye before the app exits)")
    func queueFlush() {
        final class Slow: OSCSender, @unchecked Sendable {
            let lock = NSLock()
            var sent: [OSCMessage] = []
            func send(_ message: OSCMessage) {
                Thread.sleep(forTimeInterval: 0.02)
                lock.withLock { sent.append(message) }
            }
        }
        let inner = Slow()
        let queue = DisplayFeedQueue(inner)
        queue.send(OSCMessage("/a", [.int(1)]))
        queue.send(bundle: [Self.goodbye])
        queue.flush(timeout: 1)
        #expect(inner.lock.withLock { inner.sent } == [OSCMessage("/a", [.int(1)]), Self.goodbye])
    }
}
