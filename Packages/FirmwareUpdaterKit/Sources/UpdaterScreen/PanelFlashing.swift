import PanelFlasher

/// Puts the catalog's newest deck panel image on the panel over its cable (#687), reporting each step as PanelUpdate
/// does. The app's one opens the panel's port; tests use a stand-in.
public protocol PanelFlashing: Sendable {
    func flash(report: @escaping @Sendable (PanelUpdate.Step) -> Void) async
}
