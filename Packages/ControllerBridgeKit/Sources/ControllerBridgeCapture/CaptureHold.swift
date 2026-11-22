/// When the capture window has the bridge pause the captured controller, and when it gives it back (#326). The app
/// applies the actions (Coordinator.setCapture); the rules are here, where they're tested.
public struct CaptureHold: Sendable {
    public enum Action: Equatable, Sendable {
        /// Pause the bridge's control of this source.
        case pause(Int32)
        /// Give the controller back to the bridge, which repaints its LEDs.
        case giveBack
    }

    /// The captured source, or nil for the demo controller, which the bridge never drives.
    public let source: Int32?
    public private(set) var paused = false

    public init(source: Int32?) {
        self.source = source
    }

    /// The steps begin: the controller's moves mustn't reach Syndicate.
    public mutating func stepsStarted() -> Action? { pause() }

    /// The steps are done: the bridge has it back until an LED test.
    public mutating func stepsDone() -> Action? { giveBack() }

    /// The LED test starts: held again, LEDs included, so the bridge doesn't paint over a probe (#187).
    public mutating func ledTestStarted() -> Action? { pause() }

    /// After each send: once the test is over and its last off message has gone out, give it back.
    public mutating func sendsDrained(phase: CaptureFlow.Phase, pending: Bool) -> Action? {
        guard phase == .done, !pending else { return nil }
        return giveBack()
    }

    /// The controller came back: an unplug ended the bridge's pause, so pause it again if it was paused.
    public mutating func reconnected() -> Action? {
        guard paused, let source else { return nil }
        return .pause(source)
    }

    /// The window closed or the app is quitting.
    public mutating func end() -> Action? { giveBack() }

    private mutating func pause() -> Action? {
        guard let source else { return nil }
        paused = true
        return .pause(source)
    }

    private mutating func giveBack() -> Action? {
        guard paused else { return nil }
        paused = false
        return .giveBack
    }
}
