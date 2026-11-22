/// The firmware versions an LC6000's two chips run: `wd`, the jog wheel and display, and `tp`, the top panel.
/// Filled by the unit check (#692), as the versions read like "00.50".
public struct LC6000Firmware: Sendable, Hashable {
    public let wd: String
    public let tp: String

    public init(wd: String, tp: String) {
        self.wd = wd
        self.tp = tp
    }
}
