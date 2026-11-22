import Foundation
import Synchronization

/// The display feed's sender (#490, #616): every send is handed to a worker, so the Coordinator's event path never
/// waits on the network. Once the worker is `backlog` sends behind, later sends are dropped and counted, never queued:
/// the feed must not slow DeckBridge however fast Syndicate's feedback comes (#490 story 25).
public final class DisplayFeedQueue: OSCSender, OSCFlushing {
    /// Runs a job on the worker.
    public typealias Run = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let inner: any OSCSender
    private let backlog: Int
    private let run: Run
    private struct State {
        var pending = 0
        var dropped = 0
        var trace: TraceSink?
        /// Sends dropped since the last one taken: the trace's "sending again" line counts them.
        var droppedSinceSent = 0
    }
    private let state = Mutex(State())

    /// `inner` is the display's UDP destination; `run` puts a job on the worker.
    public init(_ inner: any OSCSender, backlog: Int = 32, run: @escaping Run) {
        self.inner = inner
        self.backlog = backlog
        self.run = run
    }

    /// On its own serial queue.
    public convenience init(_ inner: any OSCSender, backlog: Int = 32) {
        let queue = DispatchQueue(label: "DeckBridge display feed")
        self.init(inner, backlog: backlog) { queue.async(execute: $0) }
    }

    /// The Debug trace (#636): when it starts dropping, and when it sends again.
    public var trace: TraceSink? {
        get { state.withLock { $0.trace } }
        set { state.withLock { $0.trace = newValue } }
    }

    /// Waits until every send queued before it has gone to the destination, at most `timeout` seconds (#651): the
    /// goodbye leaves before the app exits.
    public func flush(timeout: Double) {
        let done = DispatchSemaphore(value: 0)
        run { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Sends dropped because the worker was behind.
    public var dropped: Int { state.withLock { $0.dropped } }

    public func send(_ message: OSCMessage) {
        enqueue { [inner] in inner.send(message) }
    }

    /// A bundle is one job and one place in the backlog, dropped whole when the worker is behind (#636).
    public func send(bundle messages: [OSCMessage]) {
        enqueue { [inner] in inner.send(bundle: messages) }
    }

    private func enqueue(_ job: @escaping @Sendable () -> Void) {
        let (taken, line, trace) = state.withLock { state -> (Bool, String?, TraceSink?) in
            guard state.pending < backlog else {
                state.dropped += 1
                state.droppedSinceSent += 1
                let first = state.droppedSinceSent == 1
                return (false, first ? "dropping sends: \(state.pending) waiting on the network" : nil, state.trace)
            }
            state.pending += 1
            let line = state.droppedSinceSent > 0 ? "sending again after \(state.droppedSinceSent) dropped" : nil
            state.droppedSinceSent = 0
            return (true, line, state.trace)
        }
        if let line { trace?(.displayFeed, line) }
        guard taken else { return }
        run { [self] in
            job()
            state.withLock { $0.pending -= 1 }
        }
    }
}
