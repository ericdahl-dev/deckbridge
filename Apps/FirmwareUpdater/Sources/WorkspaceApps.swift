import AppKit
import UnitCheck

/// The running apps' bundle ids, for the check that DeckBridge isn't running (#692).
struct WorkspaceApps: RunningApps {
    func bundleIDs() async -> [String] {
        await MainActor.run { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) }
    }
}
