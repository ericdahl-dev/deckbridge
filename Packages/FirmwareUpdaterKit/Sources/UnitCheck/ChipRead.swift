/// The LC6000's two chips, as they show in update mode.
public enum ChipKind: Sendable, Hashable {
    /// `wd`: the jog wheel and display, 1 MB.
    case display
    /// `tp`: the top panel, 256 KB.
    case topPanel
}

extension ChipKind {
    /// The settings sector, as tools/lc6000-firmware/flash-day.sh backs it up on the display chip. The top panel chip's
    /// layout (drawn_plan.py) has the same small sectors at the bottom, so the same one is read there.
    var settings: (address: UInt32, length: Int) { (0x0800_4000, 0x4000) }

    /// The app area: flash-day.sh's for the display chip; for the top panel chip from 0x08008000 (its start-up code is
    /// at 0x080081D0, tp-00.31-no-deck-select-on-hello.patch) to the end of its 256 KB.
    var app: (address: UInt32, length: Int) {
        switch self {
        case .display: (0x0800_8000, 0x7_8000)
        case .topPanel: (0x0800_8000, 0x3_8000)
        }
    }
}

/// What the unit check reads from one chip: its settings sector and its app area.
public struct ChipRead: Sendable, Hashable {
    public let kind: ChipKind
    public let settings: [UInt8]
    public let app: [UInt8]

    public static func read(_ kind: ChipKind, from reader: DFUReader) async throws -> ChipRead {
        let settings = try await reader.read(address: kind.settings.address, length: kind.settings.length)
        let app = try await reader.read(address: kind.app.address, length: kind.app.length)
        return ChipRead(kind: kind, settings: settings, app: app)
    }
}
