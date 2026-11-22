// Borrowing the deck panel's USB port from DeckBridge for an update (#710). DeckBridge holds the port while it sends
// over the cable; the updater asks it to let go, waits for its answer, and gives the port back when it's done. The
// signals stay on this Mac (the app's adapter is DistributedNotificationCenter, names only). Nothing here opens a port,
// and with no answer nothing is forced: the screen says what to do instead.

import Synchronization

/// The signals between the two apps. DeckBridge's ControllerBridgeKit has the same names.
public enum HandoffSignal: String, Sendable, CaseIterable {
    /// Updater to DeckBridge: let go of the panel's port.
    case release
    /// DeckBridge to the updater: it's free.
    case released
    /// Updater to DeckBridge: done, take it back.
    case done

    public var name: String { "dev.ericdahl.deckbridge.panel-port.\(rawValue)" }
}

/// Carries the signals: the app's adapter, or a test's fake.
public protocol HandoffChannel: Sendable {
    /// Signals heard from now on.
    func listen() -> AsyncStream<HandoffSignal>
    func post(_ signal: HandoffSignal)
}

public final class PortBorrow: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// DeckBridge let go: the port is the updater's until giveBack().
        case lent
        /// No answer in time (a DeckBridge from before #710, or hung): the port wasn't touched.
        case noAnswer
    }

    /// How long DeckBridge has to answer: it closes the port and says so in milliseconds.
    public static let answerWait = 3.0

    private let channel: any HandoffChannel
    private let sleep: @Sendable (Double) async -> Void
    private let state = Mutex(false)  // lent

    public init(channel: any HandoffChannel, sleep: @escaping @Sendable (Double) async -> Void) {
        self.channel = channel
        self.sleep = sleep
    }

    /// Asks DeckBridge for the port and waits for its answer.
    public func borrow() async -> Outcome {
        let heard = channel.listen()
        channel.post(.release)
        let sleep = sleep
        let answered = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await signal in heard where signal == .released { return true }
                return false
            }
            group.addTask {
                await sleep(Self.answerWait)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        state.withLock { $0 = answered }
        return answered ? .lent : .noAnswer
    }

    /// The update is done: DeckBridge takes the port back. Only after a lend, and once.
    public func giveBack() {
        let wasLent = state.withLock { lent in
            defer { lent = false }
            return lent
        }
        if wasLent { channel.post(.done) }
    }
}
