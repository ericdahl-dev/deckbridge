import ControllerBridgeCapture
import Testing

/// When the capture window has the bridge pause the controller, and when it gives it back (#326): the rules that were
/// App code, now here.
@Suite("Capture hold")
struct CaptureHoldTests {
    @Test("Paused for the steps, given back at Done, paused again for the LED test, given back once its lights are off")
    func lifecycle() {
        var hold = CaptureHold(source: 1001)
        #expect(hold.stepsStarted() == .pause(1001))
        #expect(hold.stepsDone() == .giveBack)
        #expect(hold.stepsDone() == nil)
        #expect(hold.ledTestStarted() == .pause(1001))
        #expect(hold.sendsDrained(phase: .leds, pending: false) == nil)   // still testing
        #expect(hold.sendsDrained(phase: .done, pending: true) == nil)    // offs still to go out
        #expect(hold.sendsDrained(phase: .done, pending: false) == .giveBack)
        #expect(hold.sendsDrained(phase: .done, pending: false) == nil)
        #expect(hold.end() == nil)
    }

    @Test("A replug while paused pauses again (an unplug ended the bridge's pause); not paused, nothing")
    func replug() {
        var hold = CaptureHold(source: 1001)
        _ = hold.stepsStarted()
        #expect(hold.reconnected() == .pause(1001))
        _ = hold.stepsDone()
        #expect(hold.reconnected() == nil)
    }

    @Test("Closing mid-capture gives the controller back; the demo controller is never paused")
    func endAndDemo() {
        var hold = CaptureHold(source: 1001)
        _ = hold.stepsStarted()
        #expect(hold.end() == .giveBack)
        var demo = CaptureHold(source: nil)
        #expect(demo.stepsStarted() == nil)
        #expect(demo.ledTestStarted() == nil)
        #expect(demo.end() == nil)
    }
}
