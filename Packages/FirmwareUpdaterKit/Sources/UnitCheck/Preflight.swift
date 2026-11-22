/// The apps running on the Mac, by bundle id. The app's adapter is NSWorkspace.
public protocol RunningApps: Sendable {
    func bundleIDs() async -> [String]
}

/// What must be true before the owner puts a chip in update mode (tools/lc6000-firmware/flash-day.sh's ready check).
public struct Preflight: Sendable {
    let apps: any RunningApps

    public init(apps: any RunningApps) { self.apps = apps }

    /// Why the check can't go on, or nil.
    public func stop() async -> String? {
        if await apps.bundleIDs().contains(Self.deckBridge) { return "DeckBridge is running. Quit it first: it talks to the LC6000." }
        return nil
    }

    /// DeckBridge's bundle id (project.yml), the same for every build of it.
    static let deckBridge = "dev.ericdahl.ControllerBridge"
}
