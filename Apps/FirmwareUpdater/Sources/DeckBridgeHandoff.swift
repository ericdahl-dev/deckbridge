// Asking DeckBridge for the deck panel's port (#710), over DistributedNotificationCenter: names only, inside this user's
// session on this Mac. Not unit-tested: the rules are FirmwareUpdaterKit's PortBorrow. The update step (#687) borrows
// with it and gives the port back when it's done.
import Foundation
import PortHandoff

struct DeckBridgeHandoff: HandoffChannel {
    func listen() -> AsyncStream<HandoffSignal> {
        AsyncStream { continuation in
            let center = DistributedNotificationCenter.default()
            let observers = HandoffSignal.allCases.map { signal in
                center.addObserver(forName: .init(signal.name), object: nil, queue: nil) { _ in continuation.yield(signal) }
            }
            let box = Observers(observers)
            continuation.onTermination = { _ in
                for observer in box.list { center.removeObserver(observer) }
            }
        }
    }

    func post(_ signal: HandoffSignal) {
        DistributedNotificationCenter.default()
            .postNotificationName(.init(signal.name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func borrow() -> PortBorrow {
        PortBorrow(channel: DeckBridgeHandoff()) { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    }
}

/// The observers, held until the stream ends.
private final class Observers: @unchecked Sendable {
    let list: [NSObjectProtocol]
    init(_ list: [NSObjectProtocol]) { self.list = list }
}
