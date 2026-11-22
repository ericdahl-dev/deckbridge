// The patched app area (#693), built on the Mac from the owner's own backup and the catalog's patch set, as the flash
// kit's dfupatch.py builds it (tools/lc6000-firmware/vectors.json pins the two equal). The display chip's image gets
// its trailer CRC done again; the top panel chip's has none. Nothing here touches a device.
import FirmwareCatalog
import UnitCheck

public enum PatchedImage {
    /// Where both chips' app areas start, as the unit check reads them.
    public static let base: UInt32 = 0x0800_8000
    static let trailerSize = 32
    static let endToken = Array("EndOfFlashToken\u{0}".utf8)

    public struct Refused: Error, Equatable {
        public let reason: String
    }

    /// The app area with every edit made, after checking each one's old bytes. Refuses an edit outside the image, into
    /// its trailer, over another edit, or on bytes that aren't its old ones, and a display image whose CRC is wrong.
    public static func apply(_ edits: [PatchEdit], chip: Chip, to app: [UInt8]) throws(Refused) -> [UInt8] {
        let imageEnd = try end(of: app, chip: chip)
        if chip == .wd, DisplayTrailer.crc(of: app) == nil {
            throw Refused(reason: "the display image's trailer CRC doesn't match: refusing to build on it")
        }
        var out = app
        var taken: [Range<Int>] = []
        for edit in edits {
            guard edit.address >= base, Int(edit.address - base) + edit.old.count <= imageEnd else {
                throw Refused(reason: "an edit at \(hex(edit.address)) is outside the image")
            }
            let at = Int(edit.address - base)
            let range = at..<(at + edit.old.count)
            guard range.upperBound <= imageEnd - trailerSize else {
                throw Refused(reason: "an edit at \(hex(edit.address)) reaches into the image's trailer")
            }
            guard !taken.contains(where: { $0.overlaps(range) }) else {
                throw Refused(reason: "an edit at \(hex(edit.address)) overlaps another")
            }
            taken.append(range)
            guard Array(app[range]) == edit.old else {
                throw Refused(reason: "the bytes at \(hex(edit.address)) aren't the patch's old bytes: wrong image or wrong patch")
            }
            out.replaceSubrange(range, with: edit.new)
        }
        if chip == .wd {
            let covered = out.count - 20
            let crc = DisplayTrailer.stm32CRC(out[..<covered])
            for i in 0..<4 { out[covered + i] = UInt8(crc >> (8 * UInt32(i)) & 0xFF) }
        }
        return out
    }

    /// Where the image ends in the app area: the display chip's fills it; the top panel chip's ends with its last end
    /// token, and 0xFF follows.
    static func end(of app: [UInt8], chip: Chip) throws(Refused) -> Int {
        switch chip {
        case .wd:
            guard app.count >= trailerSize, Array(app.suffix(16)) == endToken else {
                throw Refused(reason: "the display image doesn't end with its trailer")
            }
            return app.count
        case .tp:
            var at = app.count - endToken.count
            while at >= trailerSize - endToken.count {
                if app[at] == endToken[0], Array(app[at..<(at + endToken.count)]) == endToken { return at + endToken.count }
                at -= 1
            }
            throw Refused(reason: "the top panel image has no end token")
        }
    }

    static func hex(_ address: UInt32) -> String { "0x" + String(address, radix: 16, uppercase: true) }
}
