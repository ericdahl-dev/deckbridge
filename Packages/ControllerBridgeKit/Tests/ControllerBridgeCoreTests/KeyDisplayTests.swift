import Foundation
@testable import ControllerBridgeCore
import Testing

/// Settings' Key display (#590) at the Coordinator: the jog display's key in Camelot, at once. Syndicate's TrackInfo
/// carries "A#m" (JogDisplayContentTests.trackInfo), which is 3A on the wheel.
@Suite("Key display")
struct KeyDisplayTests {
    typealias Handshake = DrawnDisplayHandshakeTests
    typealias Message = DrawnDisplay.Message

    @Test("Drawn display: the change sends the key's new text in its existing field, and back")
    func drawn() throws {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        rig.coordinator.jogDisplayReply(Handshake.answer)
        port.wd.removeAll()
        rig.coordinator.setKeyDisplay(.camelot)
        #expect(Handshake.drawn(port) == [Message.text(.key, "3A").bytes])
        port.wd.removeAll()
        rig.coordinator.setKeyDisplay(.traditional)
        #expect(Handshake.drawn(port) == [Message.text(.key, "A#m").bytes])
    }

    @Test("Drawn display: set before begin, the full state carries the Camelot key")
    func drawnFromTheStart() throws {
        let (rig, port, _) = try Handshake.rig(.custom)
        rig.coordinator.setKeyDisplay(.camelot)
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        port.wd.removeAll()
        rig.coordinator.jogDisplayReply(Handshake.answer)
        #expect(Handshake.drawn(port).contains(Message.text(.key, "3A").bytes))
        #expect(!Handshake.drawn(port).contains(Message.text(.key, "A#m").bytes))
    }

    @Test("Image mode re-renders the deck with the Camelot key, and the preview follows")
    func imagesAndPreview() throws {
        let (rig, take) = try JogDisplayPreviewNoControllerTests.rig()
        rig.coordinator.setJogPreviewDeck(1)
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        _ = take()
        rig.coordinator.setKeyDisplay(.camelot)
        let events = take()
        #expect(events.contains { if case .preview(let content) = $0 { content.deck == 1 && content.key == "3A" } else { false } })
        #expect(events.contains { if case .uploadStarted(_, let content, _) = $0 { content.key == "3A" } else { false } })
    }

    @Test("The setting reaches the Coordinator through the pipe")
    func fromThePipe() async throws {
        let (rig, take) = try JogDisplayPreviewNoControllerTests.rig()
        rig.coordinator.setJogPreviewDeck(1)
        rig.coordinator.feedback(JogDisplayContentTests.trackInfo(deck: 1))
        _ = take()
        let pipe = EventPipe()
        pipe.producer.send(.setKeyDisplay(.camelot))
        pipe.producer.finish()
        await Engine(coordinator: rig.coordinator, log: rig.log).run(pipe.events)
        #expect(take().contains { if case .preview(let content) = $0 { content.key == "3A" } else { false } })
    }
}
