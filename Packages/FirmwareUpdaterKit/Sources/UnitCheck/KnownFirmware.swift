import CryptoKit
import Foundation

/// What the app knows of each chip's firmware, as numbers only, never the firmware itself: the display chip's trailer
/// CRC and the top panel chip's SHA-256 (hex), each to its version.
public struct KnownFirmware: Sendable, Hashable {
    public let display: [UInt32: String]
    public let topPanel: [String: String]
    /// Our patched images, by the same numbers, to the version each was built on.
    public let displayOurs: [UInt32: String]
    public let topPanelOurs: [String: String]

    public init(display: [UInt32: String], topPanel: [String: String],
                displayOurs: [UInt32: String] = [:], topPanelOurs: [String: String] = [:]) {
        self.display = display
        self.topPanel = topPanel
        self.displayOurs = displayOurs
        self.topPanelOurs = topPanelOurs
    }

    public func identify(_ read: ChipRead) -> Identified {
        let off = " Updates are off; a backup is still allowed."
        switch read.kind {
        case .display:
            guard let crc = DisplayTrailer.crc(of: read.app) else {
                return Identified(kind: .display, version: nil,
                                  refusal: "The display chip's firmware doesn't match its own CRC, so it may be damaged." + off)
            }
            if let version = displayOurs[crc] { return Identified(kind: .display, version: version, refusal: nil, ours: true) }
            guard let version = display[crc] else {
                return Identified(kind: .display, version: nil, refusal:
                    "The display chip runs firmware this app doesn't know (CRC \(String(format: "0x%08X", crc)))." + off)
            }
            return Identified(kind: .display, version: version, refusal: nil)
        case .topPanel:
            let hash = SHA256.hash(data: read.app).map { String(format: "%02x", $0) }.joined()
            if let version = topPanelOurs[hash] { return Identified(kind: .topPanel, version: version, refusal: nil, ours: true) }
            guard let version = topPanel[hash] else {
                return Identified(kind: .topPanel, version: nil,
                                  refusal: "The top panel chip runs firmware this app doesn't know." + off)
            }
            return Identified(kind: .topPanel, version: version, refusal: nil)
        }
    }
}

/// A chip's firmware as the unit check found it.
public struct Identified: Sendable, Hashable {
    public let kind: ChipKind
    public let version: String?
    /// Why updates are off, or nil.
    public let refusal: String?
    /// One of our patched images is already on the chip.
    public var ours: Bool = false
    /// A read-only backup of the owner's own unit is always allowed (#692, the owner's spec answer).
    public var backupAllowed: Bool { true }
}
