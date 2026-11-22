// What an LC6000 update writes (#693): only the flash sectors whose bytes change between the backup and the patched
// image, each erased and written whole. Every other sector is untouched, and restore writes the same sectors back.
import UnitCheck

public struct WritePlan: Sendable, Equatable {
    /// One sector: where it starts, and every byte it holds once written.
    public struct Sector: Sendable, Equatable {
        public let address: UInt32
        public let bytes: [UInt8]
    }

    public let chip: ChipKind
    public let sectors: [Sector]
    /// How many bytes differ from the backup.
    public let changedBytes: Int
    private let backup: [UInt8]

    /// `backup` and `patched`: the chip's app area, as the unit check reads it and as the patch makes it.
    public init(chip: ChipKind, backup: [UInt8], patched: [UInt8]) {
        precondition(backup.count == patched.count && backup.count == chip.app.length)
        self.chip = chip
        self.backup = backup
        var sectors: [Sector] = [], changed = 0
        for (start, length) in chip.flashSectors {
            // Below the app area (the start-up code, the settings) is never written.
            guard start >= chip.app.address else { continue }
            let from = Int(start - chip.app.address), to = from + length
            guard to <= patched.count else { continue }
            let differ = zip(backup[from..<to], patched[from..<to]).filter { $0 != $1 }.count
            guard differ > 0 else { continue }
            changed += differ
            sectors.append(Sector(address: start, bytes: Array(patched[from..<to])))
        }
        self.sectors = sectors
        changedBytes = changed
    }

    private init(chip: ChipKind, sectors: [Sector], changedBytes: Int, backup: [UInt8]) {
        self.chip = chip
        self.sectors = sectors
        self.changedBytes = changedBytes
        self.backup = backup
    }

    /// The same sectors with the backup's bytes: what the restore button writes.
    public var restore: WritePlan {
        let sectors = sectors.map { sector in
            let from = Int(sector.address - chip.app.address)
            return Sector(address: sector.address, bytes: Array(backup[from..<(from + sector.bytes.count)]))
        }
        return WritePlan(chip: chip, sectors: sectors, changedBytes: changedBytes, backup: backup)
    }

    /// Exactly what is written where, for the confirm.
    public var text: String {
        let name = chip == .display ? "The display chip" : "The top panel chip"
        let ranges = sectors.map { "\(Self.hex($0.address))-\(Self.hex($0.address + UInt32($0.bytes.count) - 1)) (\($0.bytes.count / 1024) KB)" }
        let list = ranges.count > 1 ? ranges.dropLast().joined(separator: ", ") + " and " + ranges.last! : ranges.joined()
        let count = sectors.count == 1 ? "1 flash sector is" : "\(sectors.count) flash sectors are"
        let bytes = changedBytes == 1 ? "1 byte differs" : "\(changedBytes) bytes differ"
        return "\(name): \(count) erased and written with the patched image, \(list). \(bytes) from your backup. "
            + "Every other sector is untouched."
    }

    static func hex(_ value: UInt32) -> String { "0x" + String(format: "%08X", value) }
}

extension ChipKind {
    /// The flash sectors, as the chip's layout in update mode gives them (UpdateModeDevices): four 16 KB, one 64 KB,
    /// then 128 KB ones, seven on the display chip's 1 MB and one on the top panel chip's 256 KB.
    public var flashSectors: [(UInt32, Int)] {
        var out: [(UInt32, Int)] = [], at: UInt32 = 0x0800_0000
        let sizes = [0x4000, 0x4000, 0x4000, 0x4000, 0x1_0000] + Array(repeating: 0x2_0000, count: self == .display ? 7 : 1)
        for size in sizes {
            out.append((at, size))
            at += UInt32(size)
        }
        return out
    }
}
