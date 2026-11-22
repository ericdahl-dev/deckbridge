import Foundation
@testable import ControllerBridgeCore
import Testing

/// The display feed after the panel restarts (#636): sends failed while it was off, the destination reopened, and from
/// then on every snapshot must still carry the deck in front as Syndicate last reported it.
@Suite("Display feed: the panel restarting")
struct DisplayFeedRestartTests {
    @Test("No controller, deck 1 loaded and playing: the destination reopening, then keepalives, keep sending deck 1 loaded with its track")
    func reopenKeepsTheDeck() throws {
        let (rig, feed) = try DisplayFeedCoordinatorTests.rig()
        DisplayFeedCoordinatorTests.layered(rig)
        rig.midi.sources.removeAll { $0.id == Rig.lc6000.id }
        rig.coordinator.devicesChanged()
        DisplayFeedCoordinatorTests.load(rig)
        MainCueTests.feed(rig, "Playing", 1)
        DisplayFeedCoordinatorTests.turnOn(rig)
        DisplayFeedCoordinatorTests.run(rig, from: 0.01, to: 5)
        feed.sent.removeAll()
        // The panel comes back: the destination opens again.
        rig.coordinator.displayFeedReady()
        DisplayFeedCoordinatorTests.run(rig, from: 5.01, to: 12)
        let loaded = feed.sent.filter { $0.address.hasSuffix("/loaded") }
        let titles = feed.sent.filter { $0.address.hasSuffix("/title") }
        #expect(!loaded.isEmpty)
        #expect(loaded.allSatisfy { $0 == OSCMessage("/DeckBridge/Display/loaded", [.int(1)]) })
        #expect(titles.allSatisfy { $0 == OSCMessage("/DeckBridge/Display/title", [.string("Daybreak")]) })
        #expect(feed.sent.filter { $0.address.hasSuffix("/deck") }.allSatisfy { $0.arguments == [.int(1)] })
    }

    @Test("Through the app's chain (queue, destination, a socket failing while the panel is off, re-resolve, ready): once sends work again, the panel gets deck 1 loaded with its track")
    func throughTheDestination() async throws {
        let (rig, _) = try DisplayFeedCoordinatorTests.rig()
        DisplayFeedCoordinatorTests.layered(rig)
        rig.midi.sources.removeAll { $0.id == Rig.lc6000.id }
        rig.coordinator.devicesChanged()
        DisplayFeedCoordinatorTests.load(rig)
        MainCueTests.feed(rig, "Playing", 1)
        let sinks = OSCDestinationTests.FakeSinks()
        let destination = OSCDestination(resolver: OSCDestinationTests.FakeResolver(), open: { try sinks.open($0, $1) },
                                         clock: rig.clock)
        // The app's pipe stands in: what the destination reports is recorded and run by the test, on its own thread.
        final class Flag: @unchecked Sendable { var failed = false, ready = false }
        let flag = Flag()
        destination.onSendFailure = { flag.failed = true }
        destination.onReady = { flag.ready = true }
        rig.coordinator.attachDisplayFeed(DisplayFeedQueue(destination) { $0() })
        rig.coordinator.feedback(DisplayFeedCoordinatorTests.factoryPalette)
        rig.coordinator.setDisplayFeed(DisplayFeedCoordinatorTests.on)
        #expect(await destination.connect(host: "192.168.1.40", port: 9100) == nil)
        if flag.ready { flag.ready = false; rig.coordinator.displayFeedReady() }
        func step(_ to: Double) async {
            var t = rig.clock.now
            while t < to - 1e-9 {
                t += 0.01
                rig.clock.now = t
                // Syndicate streams the playing deck's Position, as it did live: its feedback never goes quiet.
                MainCueTests.position(rig, Float(t))
                rig.coordinator.tick()
                if flag.failed { flag.failed = false; await destination.reresolve() }
                if flag.ready { flag.ready = false; rig.coordinator.displayFeedReady() }
            }
        }
        await step(3)
        #expect(sinks.opened.count == 1)
        // The panel powers off: every socket's sends fail.
        for sink in sinks.opened { sink.fails = true }
        sinks.failNew = true
        await step(10)
        // It's back.
        sinks.failNew = false
        for sink in sinks.opened { sink.fails = false }
        let before = sinks.opened.map(\.sent.count)
        await step(13)
        // Each datagram, a bundle since #636, read back as its messages.
        let after = try zip(sinks.opened, before + Array(repeating: 0, count: sinks.opened.count - before.count))
            .flatMap { Array($0.0.sent.dropFirst($0.1)) }
            .flatMap { try OSCPacket(decoding: $0).messages }
        let loaded1 = OSCMessage("/DeckBridge/Display/loaded", [.int(1)])
        let loaded0 = OSCMessage("/DeckBridge/Display/loaded", [.int(0)])
        let daybreak = OSCMessage("/DeckBridge/Display/title", [.string("Daybreak")])
        #expect(after.contains(loaded1))
        #expect(after.contains(daybreak))
        #expect(!after.contains(loaded0))
        #expect(sinks.opened.count > 1)
    }

    @Test("No controller, deck 1 loaded and playing: a USB device coming and going (the panel on the Mac's USB) keeps deck 1 loaded with its track on the feed")
    func deviceChangeKeepsTheDeck() throws {
        let (rig, feed) = try DisplayFeedCoordinatorTests.rig()
        DisplayFeedCoordinatorTests.layered(rig)
        rig.midi.sources.removeAll { $0.id == Rig.lc6000.id }
        rig.coordinator.devicesChanged()
        DisplayFeedCoordinatorTests.load(rig)
        MainCueTests.feed(rig, "Playing", 1)
        DisplayFeedCoordinatorTests.turnOn(rig)
        feed.sent.removeAll()
        let panel = MIDIEndpoint(id: 77, name: "USB JTAG/serial debug unit")
        rig.midi.sources.append(panel)
        rig.coordinator.devicesChanged()
        rig.midi.sources.removeAll { $0.id == 77 }
        rig.coordinator.devicesChanged(removed: [77])
        DisplayFeedCoordinatorTests.run(rig, from: 0.01, to: 2.5)
        let loaded = feed.sent.filter { $0.address.hasSuffix("/loaded") }
        #expect(loaded.allSatisfy { $0 == OSCMessage("/DeckBridge/Display/loaded", [.int(1)]) })
        #expect(feed.sent.filter { $0.address.hasSuffix("/title") }.allSatisfy { $0.arguments == [.string("Daybreak")] })
    }
}
