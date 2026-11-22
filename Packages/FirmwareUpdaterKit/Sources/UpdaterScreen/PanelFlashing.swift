import FirmwareModel
import PanelFlasher

/// What the app offers to put on the panel (#687): the catalog's version, and a note when the panel's own build is one
/// the app doesn't know.
public struct PanelUpdateOffer: Sendable, Equatable {
    public let version: String
    public let note: String?

    public init(version: String, note: String?) {
        self.version = version
        self.note = note
    }
}

/// Puts the catalog's newest deck panel image on the panel over its cable (#687), reporting each step as PanelUpdate
/// does. The app's one opens the panel's port; tests use a stand-in.
public protocol PanelFlashing: Sendable {
    /// The update for a panel running `build`; nil when there's nothing newer to put on it.
    func offer(for build: PanelBuild) -> PanelUpdateOffer?
    /// The version a repair writes (the catalog's newest image), for a panel whose build can't be read; nil with none.
    func repairVersion() -> String?
    func flash(report: @escaping @Sendable (PanelUpdate.Step) -> Void) async
}
