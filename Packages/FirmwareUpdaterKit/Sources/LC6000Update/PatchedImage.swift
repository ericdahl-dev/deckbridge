// The patched app area (#693), built on the Mac from the owner's own backup and the catalog's patch set, as the flash
// kit's dfupatch.py builds it (tools/lc6000-firmware/vectors.json pins the two equal). The display chip's image gets
// its trailer CRC done again; the top panel chip's has none. Nothing here touches a device.
import CryptoKit
import FirmwareCatalog
import UnitCheck

/// What a chip runs, against a patch for its stock version.
public enum PatchState: Sendable, Equatable {
    /// The stock version the patch is for: it can be patched.
    case stock(String)
    /// Stock with this patch already in it, the image whole (the display chip's CRC good): up to date.
    case alreadyPatched(String)
    /// Neither: no update is offered.
    case unknown
}

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

    /// Whether `app` is the stock image the edits are for, the same with them made, or neither. Already patched means
    /// every edit's new bytes are there, the display image's CRC is good, and with the old bytes back it's stock.
    public static func state(of app: [UInt8], chip: Chip, edits: [PatchEdit], known: KnownNumbers) -> PatchState {
        if let version = stockVersion(app, chip: chip, known: known) { return .stock(version) }
        // apply checks the display CRC before it builds on the image, so a damaged one is refused here too.
        let undone = edits.map { PatchEdit(address: $0.address, old: $0.new, new: $0.old) }
        guard let stock = try? apply(undone, chip: chip, to: app),
              let version = stockVersion(stock, chip: chip, known: known) else { return .unknown }
        return .alreadyPatched(version)
    }

    static func stockVersion(_ app: [UInt8], chip: Chip, known: KnownNumbers) -> String? {
        switch chip {
        case .wd: DisplayTrailer.crc(of: app).flatMap { known.display[$0] }
        case .tp: known.topPanel[SHA256.hash(data: app).map { String(format: "%02x", $0) }.joined()]
        }
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
