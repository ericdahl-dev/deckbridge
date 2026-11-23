/// A device in ST's update mode, as the USB list shows it: its USB path and its alt settings' names. No serial number:
/// ST's bootloader makes it from the chip's own ID, so it is never read.
public struct DFUDevice: Sendable, Hashable {
    public let path: String
    public let altNames: [String]

    public init(path: String, altNames: [String]) {
        self.path = path
        self.altNames = altNames
    }
}

public enum UpdateModeDevices {
    public enum Judgment: Sendable, Hashable {
        case one(ChipKind, path: String)
        case refused(String)
    }

    /// The chips' flash layouts, as their alt names give them (tools/lc6000-firmware/drawn_plan.py).
    static let displayLayout = "/0x08000000/04*016Kg,01*064Kg,07*128Kg"   // 1 MB
    static let topPanelLayout = "/0x08000000/04*016Kg,01*064Kg,01*128Kg"  // 256 KB

    /// Exactly one device, and one of the LC6000's chips by its layout: drawn_plan.py's judge_devices, for either chip.
    public static func judge(_ devices: [DFUDevice]) -> Judgment {
        guard let device = devices.first else { return .refused("No device in update mode.") }
        guard devices.count == 1 else {
            return .refused("\(devices.count) devices are in update mode. Exactly one is needed: power the LC6000 off and on, "
                            + "then put one chip in update mode.")
        }
        if device.altNames.contains(where: { $0.contains(displayLayout) }) { return .one(.display, path: device.path) }
        if device.altNames.contains(where: { $0.contains(topPanelLayout) }) { return .one(.topPanel, path: device.path) }
        return .refused("Its memory layout is neither LC6000 chip's, so it isn't one. Nothing was read.")
    }
}
