import DeviceFinder
import Foundation
import Testing
import UnitCheck

final class Lines: LogSink, @unchecked Sendable {
    let lock = NSLock()
    var lines: [String] = []
    func log(_ line: String) { lock.withLock { lines.append(line) } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

/// A display chip holding the made-up wd image at 0x08008000.
func madeUpDisplayChip() -> FakeChip {
    var flash = FakeChip(size: 0x10_0000).flash
    flash.replaceSubrange(0x8000..<0x8_0000, with: madeUpDisplayApp())
    return FakeChip(flash: flash)
}

@Suite("Unit check: the whole backup, and its log")
struct UnitCheckLogTests {
    @Test("A display chip backed up: the result has its version and files, and the log says what was done")
    func backedUp() async throws {
        let folder = try freshFolder()
        let lines = Lines()
        let result = await UnitCheck(known: known, log: lines).backUp(
            devices: [DFUDevice(path: "20-1", altNames: [displayAlt])], transport: madeUpDisplayChip(), into: folder, stamp: stamp)
        #expect(result.identified?.version == "00.50")
        #expect(result.files.count == 2)
        #expect(result.refusal == nil)
        #expect(lines.lines == [
            "LC6000 display chip in update mode",
            "LC6000 display chip: firmware 00.50, CRC 0x3D498706",
            "LC6000 display chip: backup saved, read twice and the same (2 files)",
        ])
    }

    @Test("Refused or failed: the log has the plain reason")
    func refusedIsLogged() async throws {
        let lines = Lines()
        let result = await UnitCheck(known: known, log: lines).backUp(devices: [], transport: madeUpDisplayChip(),
                                                                      into: try freshFolder(), stamp: stamp)
        #expect(result.refusal == "No device in update mode.")
        #expect(lines.lines == ["LC6000: no backup: No device in update mode."])
    }

    @Test("The log leaves out the USB path, the serial number, the backup folder and any firmware bytes")
    func logLeavesOutPrivateDetails() async throws {
        let folder = try freshFolder().appendingPathComponent("Ada Lovelace's backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = Lines()
        _ = await UnitCheck(known: KnownFirmware(display: [:], topPanel: [:]), log: lines).backUp(
            devices: [DFUDevice(path: "20-1.4", altNames: [displayAlt, "serial 3276375C3033"])],
            transport: madeUpDisplayChip(), into: folder, stamp: stamp)
        let log = lines.text
        #expect(log.contains("doesn't know"))
        for secret in ["20-1.4", "3276375C3033", "Ada", "Lovelace", folder.path, "EndOfFlashToken", "DEADBEEF"] {
            #expect(!log.contains(secret), "log has \(secret)")
        }
    }
}
