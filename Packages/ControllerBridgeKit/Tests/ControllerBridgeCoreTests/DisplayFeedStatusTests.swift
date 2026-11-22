import ControllerBridgeCore
import Foundation
import Testing

/// The display feed's status line in Settings (#618): what it's doing, so a feed that can't send never fails silently.
/// Read from the setting and the feed's destination, with fake sockets: no network.
@Suite("Display feed: the status line")
struct DisplayFeedStatusTests {
    typealias Sinks = OSCDestinationTests.FakeSinks
    typealias Resolver = OSCDestinationTests.FakeResolver

    static let on = DisplayFeedSettings(enabled: true, host: "192.168.1.40", port: 9100)

    @Test("Off says so; on with nothing open yet is connecting; open is sending, to the host and port")
    func offConnectingSending() async {
        let sinks = Sinks()
        let destination = OSCDestinationTests.destination(sinks, Resolver())
        #expect(DisplayFeedStatus(DisplayFeedSettings(), destination) == .off)
        #expect(DisplayFeedStatus(Self.on, destination) == .connecting("192.168.1.40:9100"))
        _ = await destination.connect(host: "192.168.1.40", port: 9100)
        #expect(DisplayFeedStatus(Self.on, destination) == .sending("192.168.1.40:9100"))
        #expect(DisplayFeedStatus(Self.on, destination).text == "Sending to 192.168.1.40:9100")
        #expect(DisplayFeedStatus(DisplayFeedSettings(), destination).text == "Off")
        #expect(DisplayFeedStatus(Self.on, OSCDestinationTests.destination(Sinks(), Resolver())).text
            == "Connecting to 192.168.1.40:9100…")
    }

    @Test("A name that can't be found, or a socket that won't open, is not sending, with the reason")
    func connectFailure() async {
        let sinks = Sinks()
        let destination = OSCDestinationTests.destination(sinks, Resolver())
        let named = DisplayFeedSettings(enabled: true, host: "deck-panel.local", port: 9100)
        _ = await destination.connect(host: "deck-panel.local", port: 9100)
        #expect(DisplayFeedStatus(named, destination) == .notSending("Can't find deck-panel.local on the network"))
        #expect(DisplayFeedStatus(named, destination).text == "Not sending: Can't find deck-panel.local on the network")

        sinks.refuse = ["192.168.1.40"]
        let refused = OSCDestinationTests.destination(sinks, Resolver())
        _ = await refused.connect(host: "192.168.1.40", port: 9100)
        #expect(DisplayFeedStatus(Self.on, refused).text == "Not sending: Couldn't send OSC to 192.168.1.40:9100")
    }

    /// macOS 15 and later refuse a LAN send with "no route to host" when Local Network access is off for the app, the
    /// same error as a host that left the network: the line says both.
    @Test("Sends failing is not sending, with where macOS's Local Network switch is; a send that works again is sending")
    func sendsFailing() async {
        let sinks = Sinks()
        let destination = OSCDestinationTests.destination(sinks, Resolver())
        _ = await destination.connect(host: "192.168.1.40", port: 9100)
        sinks.sink("192.168.1.40:9100")?.fails = true
        destination.send(OSCDestinationTests.play)
        #expect(DisplayFeedStatus(Self.on, destination) == .unreachable("192.168.1.40:9100"))
        #expect(DisplayFeedStatus(Self.on, destination).text == "Not sending: can't reach 192.168.1.40:9100. If the panel is on, "
            + "macOS may be blocking local network access: turn on DeckBridge in System Settings › Privacy & Security › Local Network.")
        sinks.sink("192.168.1.40:9100")?.fails = false
        destination.send(OSCDestinationTests.play)
        #expect(DisplayFeedStatus(Self.on, destination) == .sending("192.168.1.40:9100"))
    }

    @Test("Not sending and can't reach show as problems; off, connecting and sending don't")
    func problems() {
        #expect(DisplayFeedStatus.notSending("x").isProblem)
        #expect(DisplayFeedStatus.unreachable("x").isProblem)
        #expect(!DisplayFeedStatus.off.isProblem)
        #expect(!DisplayFeedStatus.connecting("x").isProblem)
        #expect(!DisplayFeedStatus.sending("x").isProblem)
    }
}

