// The Firmware Updater's asks for the deck panel's port (#710), over DistributedNotificationCenter: names only (no
// userInfo, which the sandbox allows), inside this user's session on this Mac. Not unit-tested: the rules are the Kit's
// CableHandoff; the live path is the owner's run (release, done, and the switch toggled after an updater crash).
import ControllerBridgeCore
import Foundation

@MainActor
final class CableHandoffSignals {
    private let center = DistributedNotificationCenter.default()
    private var observers: [NSObjectProtocol] = []

    init(cable: PanelCable) {
        let center = center
        observers.append(center.addObserver(forName: .init(CableHandoff.releaseName), object: nil, queue: .main) { [weak cable] _ in
            MainActor.assumeIsolated {
                cable?.lend {
                    center.postNotificationName(.init(CableHandoff.releasedName), object: nil, userInfo: nil, deliverImmediately: true)
                }
            }
        })
        observers.append(center.addObserver(forName: .init(CableHandoff.doneName), object: nil, queue: .main) { [weak cable] _ in
            MainActor.assumeIsolated { cable?.reclaim() }
        })
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
