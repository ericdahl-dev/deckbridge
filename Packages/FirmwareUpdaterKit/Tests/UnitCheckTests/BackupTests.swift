import Foundation
import Testing
import UnitCheck

func freshFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("unitcheck-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let stamp = "20261121-101500"
/// One read of the display chip in 2048-byte blocks: the settings (0x4000) and the app (0x78000).
let displayBlocks = 248

func uploads(_ chip: FakeChip) -> Int { chip.log.filter { $0.requestType == 0xA1 && $0.request == 2 }.count }

@Suite("Unit check: the backup")
struct BackupTests {
    @Test("Read twice, the same both times: the settings and the app are saved in the folder the owner picked")
    func savedWhenBothReadsMatch() async throws {
        let folder = try freshFolder()
        let chip = FakeChip(size: 0x10_0000)
        let files = try await Backup.make(.display, reader: DFUReader(transport: chip), into: folder, stamp: stamp)
        #expect(files.map(\.lastPathComponent).sorted() == ["lc6000-wd-app-\(stamp).bin", "lc6000-wd-settings-\(stamp).bin"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("lc6000-wd-app-\(stamp).bin")) == Data(chip.flash[0x8000..<0x8_0000]))
        #expect(try Data(contentsOf: folder.appendingPathComponent("lc6000-wd-settings-\(stamp).bin")) == Data(chip.flash[0x4000..<0x8000]))
        #expect(uploads(chip) == 2 * displayBlocks) // every block read twice
        #expect(chip.log.allSatisfy(isReadOnly))
    }

    @Test("The two reads differ: nothing is saved, with a plain reason, and no third read")
    func nothingSavedWhenReadsDiffer() async throws {
        let folder = try freshFolder()
        let chip = FakeChip(size: 0x10_0000)
        chip.flipsAfterUploads = displayBlocks // the second read comes back different
        await #expect(throws: BackupError.readsDiffer) {
            try await Backup.make(.display, reader: DFUReader(transport: chip), into: folder, stamp: stamp)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
        #expect(uploads(chip) == 2 * displayBlocks)
        #expect(BackupError.readsDiffer.reason == "The two reads of the chip differ, so no backup was saved. Power the LC6000 off and on, then try again.")
    }

    @Test("A folder inside a git work tree is refused before anything is read: a backup never goes in a repo")
    func refusedInsideARepo() async throws {
        let repo = try freshFolder()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let inside = repo.appendingPathComponent("backups/lc6000")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let chip = FakeChip(size: 0x10_0000)
        await #expect(throws: BackupError.insideARepo) {
            try await Backup.make(.display, reader: DFUReader(transport: chip), into: inside, stamp: stamp)
        }
        #expect(chip.log.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inside.path) == [])
        #expect(BackupError.insideARepo.reason == "That folder is inside a git repository. Pick a folder outside any repository, so the backup is never committed.")
    }

    @Test("Top panel chip: its files say tp")
    func topPanelNames() async throws {
        let folder = try freshFolder()
        let files = try await Backup.make(.topPanel, reader: DFUReader(transport: FakeChip(size: 0x4_0000)), into: folder, stamp: stamp)
        #expect(files.map(\.lastPathComponent).sorted() == ["lc6000-tp-app-\(stamp).bin", "lc6000-tp-settings-\(stamp).bin"])
    }
}
