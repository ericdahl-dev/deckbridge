import ControllerBridgeCapture
import Testing

/// Noticing the captured controller go and come back (#315). The app hands in the sources CoreMIDI lists as online;
/// an unplugged USB device's endpoint can still be found by its id, so presence is the online list, not a lookup.
@Suite("Capture watch")
struct CaptureWatchTests {
    @Test("Gone from the online sources: disconnected, once; back: reconnected, which pauses the bridge again")
    func goneAndBack() {
        var watch = CaptureWatch(source: 1001)
        #expect(watch.sourcesChanged(online: [1000, 1001]) == nil)
        #expect(watch.sourcesChanged(online: [1000]) == .disconnected)
        #expect(watch.sourcesChanged(online: [1000]) == nil)
        #expect(watch.sourcesChanged(online: [1000, 1001]) == .reconnected)
        #expect(watch.sourcesChanged(online: [1001, 1000]) == nil)
    }

    @Test("Another device coming and going changes nothing")
    func otherDevices() {
        var watch = CaptureWatch(source: 1001)
        #expect(watch.sourcesChanged(online: [1001, 2000]) == nil)
        #expect(watch.sourcesChanged(online: [1001]) == nil)
    }
}
