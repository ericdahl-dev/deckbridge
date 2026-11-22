import ControllerBridgeCore
import Foundation
import Synchronization
import Testing

/// Where OSC goes (#84, #109): Syndicate's host by IP address or by name, resolved off the caller, with the old
/// destination kept until a new one opens. The resolver and the sockets are fakes: no network.
@Suite("OSC destination")
struct OSCDestinationTests {
    /// Sockets "opened" by the destination, by address, with what each was sent. One can be told to fail.
    final class FakeSinks: @unchecked Sendable {
        final class Sink: DatagramSink, @unchecked Sendable {
            let address: String
            var sent: [[UInt8]] = []
            var fails = false
            init(_ address: String) { self.address = address }
            func send(_ bytes: [UInt8]) throws {
                if fails { throw POSIXError(.EHOSTUNREACH) }
                sent.append(bytes)
            }
        }
        var opened: [Sink] = []
        var refuse: Set<String> = []
        /// New sockets fail their sends too, as while a host is off the network.
        var failNew = false
        func open(_ host: String, _ port: Int) throws -> any DatagramSink {
            if refuse.contains(host) { throw POSIXError(.EADDRNOTAVAIL) }
            let sink = Sink("\(host):\(port)")
            sink.fails = failNew
            opened.append(sink)
            return sink
        }
        func sink(_ address: String) -> Sink? { opened.last { $0.address == address } }
    }

    /// Answers names from a table; counts the questions.
    final class FakeResolver: HostResolver, @unchecked Sendable {
        var answers: [String: String] = [:]
        var asked: [String] = []
        func resolve(_ host: String) async throws -> String {
            asked.append(host)
            guard let ip = answers[host] else { throw POSIXError(.ENOENT) }
            return ip
        }
    }

    static let play = OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])

    static func destination(_ sinks: FakeSinks, _ resolver: any HostResolver) -> OSCDestination {
        OSCDestination(resolver: resolver, open: { try sinks.open($0, $1) }, clock: Rig.FakeClock())
    }

    @Test("An IP address opens at once, with no lookup, and sends go there")
    func ipAddress() async throws {
        let sinks = FakeSinks(), resolver = FakeResolver()
        let destination = Self.destination(sinks, resolver)
        #expect(await destination.connect(host: "192.168.1.20", port: 9090) == nil)
        destination.send(Self.play)
        #expect(resolver.asked == [])
        #expect(sinks.sink("192.168.1.20:9090")?.sent == [Self.play.encoded()])
    }

    @Test("A bundle goes out as one datagram (#636)")
    func bundleIsOneDatagram() async throws {
        let sinks = FakeSinks(), resolver = FakeResolver()
        let destination = Self.destination(sinks, resolver)
        #expect(await destination.connect(host: "192.168.1.40", port: 9100) == nil)
        let messages = [OSCMessage("/DeckBridge/Display/deck", [.int(1)]), OSCMessage("/DeckBridge/Display/loaded", [.int(1)])]
        destination.send(bundle: messages)
        #expect(sinks.sink("192.168.1.40:9100")?.sent == [OSCPacket.bundle(messages)])
    }

    @Test("A sender with no bundle of its own sends a bundle's messages one by one")
    func bundleFallback() {
        final class Plain: OSCSender, @unchecked Sendable {
            var sent: [OSCMessage] = []
            func send(_ message: OSCMessage) { sent.append(message) }
        }
        let plain = Plain()
        let messages = [OSCMessage("/a", [.int(1)]), OSCMessage("/b", [.int(2)])]
        plain.send(bundle: messages)
        #expect(plain.sent == messages)
    }

    /// Holds each lookup until the test answers it, so the test can act while a name is resolving.
    final class GatedResolver: HostResolver, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<String, any Error>] = []
        var pending: Int { lock.withLock { waiting.count } }
        func resolve(_ host: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in lock.withLock { waiting.append(continuation) } }
        }
        func answer(_ ip: String) { lock.withLock { waiting.removeFirst() }.resume(returning: ip) }
        func fail() { lock.withLock { waiting.removeFirst() }.resume(throwing: POSIXError(.ENOENT)) }
        /// Waits (briefly, in real time) until a lookup has started.
        func waitForLookup() async {
            for _ in 0..<500 where pending == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    final class Count: @unchecked Sendable { var value = 0 }

    @Test("A name at launch doesn't wait: sends are dropped while it resolves, then go to its address; onReady fires once")
    func nameResolvesInTheBackground() async throws {
        let sinks = FakeSinks(), resolver = GatedResolver(), ready = Count()
        let destination = Self.destination(sinks, resolver)
        destination.onReady = { ready.value += 1 }
        let connecting = Task { await destination.connect(host: "studio-mac.local", port: 9090) }
        await resolver.waitForLookup()

        destination.send(Self.play)                      // while resolving: dropped, nothing opened
        #expect(sinks.opened.isEmpty)

        resolver.answer("192.168.1.30")
        #expect(await connecting.value == nil)
        destination.send(Self.play)
        #expect(sinks.sink("192.168.1.30:9090")?.sent == [Self.play.encoded()])
        #expect(ready.value == 1)
    }

    @Test("A name that can't be found says so, and the old destination keeps sending")
    func unknownNameKeepsTheOldOne() async throws {
        let sinks = FakeSinks(), resolver = FakeResolver()
        let destination = Self.destination(sinks, resolver)
        #expect(await destination.connect(host: "192.168.1.20", port: 9090) == nil)
        #expect(await destination.connect(host: "studio-mac.local", port: 9090) == "Can't find studio-mac.local on the network")
        destination.send(Self.play)
        #expect(sinks.sink("192.168.1.20:9090")?.sent == [Self.play.encoded()])
    }

    @Test("A lookup that hangs gives up after the timeout with the same message, so Settings is never stuck checking")
    func hungLookupTimesOut() async throws {
        let sinks = FakeSinks(), resolver = GatedResolver()   // never answered
        let destination = OSCDestination(resolver: resolver, open: { try sinks.open($0, $1) }, clock: Rig.FakeClock(),
                                         lookupTimeout: .milliseconds(50))
        #expect(await destination.connect(host: "studio-mac.local", port: 9090) == "Can't find studio-mac.local on the network")
        #expect(sinks.opened.isEmpty)
        resolver.fail()   // let the hung lookup go
    }

    @Test("#109: a sender that can't open at launch drops sends and says why; a later good host starts sending, no restart")
    func failedLaunchFixedByApply() async throws {
        let sinks = FakeSinks(), resolver = FakeResolver()
        sinks.refuse = ["10.0.0.99"]
        let destination = Self.destination(sinks, resolver)
        let problem = await destination.connect(host: "10.0.0.99", port: 9090)
        #expect(problem == "Couldn't send OSC to 10.0.0.99:9090")
        #expect(destination.lastError == problem)
        #expect(!destination.isReady)
        destination.send(Self.play)                      // dropped, no crash
        #expect(sinks.opened.isEmpty)

        #expect(await destination.connect(host: "127.0.0.1", port: 9090) == nil)
        #expect(destination.isReady)
        #expect(destination.lastError == nil)
        destination.send(Self.play)
        #expect(sinks.sink("127.0.0.1:9090")?.sent == [Self.play.encoded()])
    }

    @Test("A failing send is reported, at most once a second, so a dead host doesn't fire on every 10 ms tick")
    func sendFailuresThrottled() async throws {
        let sinks = FakeSinks(), resolver = FakeResolver(), clock = Rig.FakeClock(), failures = Count()
        let destination = OSCDestination(resolver: resolver, open: { try sinks.open($0, $1) }, clock: clock)
        destination.onSendFailure = { failures.value += 1 }
        #expect(await destination.connect(host: "192.168.1.20", port: 9090) == nil)
        sinks.sink("192.168.1.20:9090")?.fails = true

        destination.send(Self.play)
        clock.now = 0.5
        destination.send(Self.play)
        #expect(failures.value == 1)
        #expect(destination.lastError == "Couldn't send OSC to 192.168.1.20:9090")
        clock.now = 1.1
        destination.send(Self.play)
        #expect(failures.value == 2)
    }

    @Test("Re-resolving (on send failures or wake) looks the name up again and moves to its new address")
    func reresolveMovesToNewAddress() async throws {
        let sinks = FakeSinks(), resolver = FakeResolver()
        resolver.answers = ["studio-mac.local": "192.168.1.30"]
        let destination = Self.destination(sinks, resolver)
        #expect(await destination.connect(host: "studio-mac.local", port: 9090) == nil)
        resolver.answers = ["studio-mac.local": "192.168.1.31"]   // it rejoined the network with a new address
        await destination.reresolve()
        destination.send(Self.play)
        #expect(sinks.sink("192.168.1.31:9090")?.sent == [Self.play.encoded()])
        #expect(resolver.asked == ["studio-mac.local", "studio-mac.local"])
    }

    @Test("Only one re-resolve runs at a time: a second request while one is in flight doesn't start another lookup")
    func oneReresolveInFlight() async throws {
        let sinks = FakeSinks(), resolver = GatedResolver()
        let destination = Self.destination(sinks, resolver)
        let first = Task { await destination.connect(host: "studio-mac.local", port: 9090) }
        await resolver.waitForLookup()
        resolver.answer("192.168.1.30")
        _ = await first.value

        let again = Task { await destination.reresolve() }
        await resolver.waitForLookup()
        await destination.reresolve()                  // in flight already: returns without a second lookup
        #expect(resolver.pending == 1)
        resolver.answer("192.168.1.31")
        await again.value
        destination.send(Self.play)
        #expect(sinks.sink("192.168.1.31:9090")?.sent == [Self.play.encoded()])
    }

    @Test("When the destination opens late, a resync through the pipe asks Syndicate for its state once")
    func resyncThroughThePipe() async throws {
        let rig = try Rig()
        rig.coordinator.start()
        rig.coordinator.feedback(OSCMessage("/Syndicate/Deck/1/Playing", [.int(0)]))   // the start Resend was answered
        rig.osc.sent.removeAll()
        let pipe = EventPipe()
        pipe.producer.send(.resync)
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Feedback/Resend", [.int(1)])])
    }

    @Test("A resync sends a Resend even if the start-up one is still waiting: that one went out before the destination opened")
    func resyncAfterADroppedResend() throws {
        let rig = try Rig()
        rig.coordinator.start()                          // its Resend was dropped: no destination yet
        rig.osc.sent.removeAll()
        rig.coordinator.resync()
        #expect(rig.osc.sent == [OSCMessage("/Syndicate/Feedback/Resend", [.int(1)])])
    }

    // #135: of two connects in flight, the newer one wins, whichever finishes last.

    @Test("A slow lookup that finishes after a newer connect changes nothing: sends go to the newer host, onReady fires once")
    func lateLookupLoses() async throws {
        let sinks = FakeSinks(), resolver = GatedResolver(), ready = Count()
        let destination = OSCDestination(resolver: resolver, open: { try sinks.open($0, $1) }, clock: Rig.FakeClock(),
                                         lookupTimeout: .seconds(30))
        destination.onReady = { ready.value += 1 }
        let slow = Task { await destination.connect(host: "old-studio.local", port: 9090) }
        await resolver.waitForLookup()
        #expect(await destination.connect(host: "192.168.1.20", port: 9090) == nil)
        resolver.answer("10.0.0.9")
        #expect(await slow.value == nil)                // superseded: nothing to report
        destination.send(OSCMessage("/Syndicate/Feedback/Resend", [.int(1)]))
        #expect(sinks.sink("192.168.1.20:9090")?.sent.count == 1)
        #expect(sinks.sink("10.0.0.9:9090") == nil)    // never opened
        #expect(ready.value == 1)
    }

    @Test("A slow lookup that fails after a newer connect opened doesn't set lastError")
    func lateFailureLoses() async throws {
        let sinks = FakeSinks(), resolver = GatedResolver()
        sinks.refuse = ["10.0.0.9"]
        let destination = OSCDestination(resolver: resolver, open: { try sinks.open($0, $1) }, clock: Rig.FakeClock(),
                                         lookupTimeout: .seconds(30))
        let slow = Task { await destination.connect(host: "old-studio.local", port: 9090) }
        await resolver.waitForLookup()
        #expect(await destination.connect(host: "192.168.1.20", port: 9090) == nil)
        resolver.answer("10.0.0.9")
        #expect(await slow.value == nil)
        #expect(destination.lastError == nil)
        #expect(destination.isReady)
    }

    @Test("A re-resolve started before an Apply doesn't undo it: sends go to the applied host")
    func reresolveLosesToApply() async throws {
        let sinks = FakeSinks(), resolver = GatedResolver()
        let destination = OSCDestination(resolver: resolver, open: { try sinks.open($0, $1) }, clock: Rig.FakeClock(),
                                         lookupTimeout: .seconds(30))
        let first = Task { await destination.connect(host: "studio.local", port: 9090) }
        await resolver.waitForLookup()
        resolver.answer("10.0.0.5")
        _ = await first.value
        let again = Task { await destination.reresolve() }       // after a wake, say
        await resolver.waitForLookup()
        #expect(await destination.connect(host: "192.168.1.20", port: 9090) == nil)
        resolver.answer("10.0.0.9")
        await again.value
        destination.send(OSCMessage("/Syndicate/Feedback/Resend", [.int(1)]))
        #expect(sinks.sink("192.168.1.20:9090")?.sent.count == 1)
        #expect(sinks.sink("10.0.0.9:9090") == nil)
    }

    /// For the display feed's status (#618): whether sends are failing now, apart from why a connect failed. Kept
    /// apart from `lastError`, which the Syndicate link's problem reporting reads and which stays as it was.
    @Test("A failing send marks sends failing, a good one clears it; lastError still keeps the send failure; a failed connect is the connect problem")
    func sendsFailingAndConnectProblem() async {
        let sinks = FakeSinks(), resolver = FakeResolver()
        let destination = Self.destination(sinks, resolver)
        _ = await destination.connect(host: "192.168.1.20", port: 9090)
        #expect(!destination.sendsFailing)
        sinks.sink("192.168.1.20:9090")?.fails = true
        destination.send(Self.play)
        #expect(destination.sendsFailing)
        #expect(destination.connectProblem == nil)
        sinks.sink("192.168.1.20:9090")?.fails = false
        destination.send(Self.play)
        #expect(!destination.sendsFailing)
        #expect(destination.lastError == "Couldn't send OSC to 192.168.1.20:9090")  // unchanged: the Syndicate link's

        _ = await destination.connect(host: "nowhere.local", port: 9090)
        #expect(destination.connectProblem == "Can't find nowhere.local on the network")
        resolver.answers["panel.local"] = "192.168.1.41"
        _ = await destination.connect(host: "panel.local", port: 9090)
        #expect(destination.connectProblem == nil)
    }
}

