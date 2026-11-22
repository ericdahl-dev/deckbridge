import Foundation
import Testing
import UnitCheck

/// Before block B is written (#751), the area it goes in, 0x08080000-0x080FFFFF, is read twice, compared, and saved
/// outside any repository, as #709 backs up the app. Made-up bytes on a fake chip.
@Suite("Block B: the backup of the area above the image")
struct UpperBackupTests {
    static func chip(upper fill: UInt8 = 0xFF) -> FlashChip {
        var flash = [UInt8](repeating: 0x5A, count: 0x10_0000)
        for i in 0x8_0000..<0x10_0000 { flash[i] = fill }
        flash[0x8_0000] = 0x44  // a byte that isn't the fill, so the read is the chip's
        return FlashChip(flash: flash, sectors: ChipKind.display.flashSectors)
    }

    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "upper-backup-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Read twice and the same: saved as one file of the 512 KB above the image")
    func saved() async throws {
        let chip = Self.chip(upper: 0x77)
        let folder = Self.folder()
        let saved = try await Backup.upper(reader: DFUReader(transport: chip), into: folder, stamp: "t1")
        #expect(saved.bytes == chip.bytes(0x0808_0000, 0x8_0000))
        #expect(saved.file.lastPathComponent == "lc6000-display-upper-t1.bin")
        #expect(try Data(contentsOf: saved.file) == Data(saved.bytes))
    }

    @Test("Two reads that differ: nothing saved")
    func readsDiffer() async throws {
        let folder = Self.folder()
        await #expect(throws: BackupError.readsDiffer) {
            _ = try await Backup.upper(reader: DFUReader(transport: Flaky(Self.chip())), into: folder, stamp: "t2")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("A folder inside a git repository: refused before anything is read")
    func insideARepo() async throws {
        let folder = Self.folder()
        try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
        let chip = Self.chip()
        await #expect(throws: BackupError.insideARepo) {
            _ = try await Backup.upper(reader: DFUReader(transport: chip), into: folder, stamp: "t3")
        }
        #expect(chip.log.isEmpty)
    }

    /// The first read's first block comes back with one byte changed: the two reads differ.
    final class Flaky: DFUTransport, @unchecked Sendable {
        let inner: FlashChip
        var changed = false
        init(_ inner: FlashChip) { self.inner = inner }
        func control(_ r: DFURequest) async throws -> [UInt8] {
            var answer = try await inner.control(r)
            if r.requestType == 0xA1, r.request == 2, !changed, !answer.isEmpty {
                changed = true
                answer[0] ^= 0x01
            }
            return answer
        }
    }
}
