import DeviceFinder
import Foundation

/// The LC6000 section's check and backup (#692), with nothing written to the unit: which chip is in update mode, a
/// backup read twice, and which firmware it runs. The log says what was done, in fixed words and numbers only.
public struct UnitCheck: Sendable {
    public struct Result: Sendable, Hashable {
        public var identified: Identified?
        public var files: [URL] = []
        public var refusal: String?
        /// What was read and saved: an update's plan is built from it, in this run of the app only (#693).
        public var read: ChipRead?
    }

    let known: KnownFirmware
    let log: any LogSink

    public init(known: KnownFirmware, log: any LogSink) {
        self.known = known
        self.log = log
    }

    public func backUp(devices: [DFUDevice], transport: any DFUTransport, into folder: URL, stamp: String) async -> Result {
        let kind: ChipKind
        switch UpdateModeDevices.judge(devices) {
        case .one(let one, _): kind = one
        case .refused(let reason): return refused(reason)
        }
        let chip = kind == .display ? "LC6000 display chip" : "LC6000 top panel chip"
        log.log("\(chip) in update mode")
        let saved: (read: ChipRead, files: [URL])
        do {
            saved = try await Backup.reading(kind, reader: DFUReader(transport: transport), into: folder, stamp: stamp)
        } catch let error as BackupError {
            return refused(error.reason)
        } catch let error as DFUError {
            return refused(error.reason)
        } catch {
            return refused("The backup couldn't be written to that folder. Nothing was saved.")
        }
        let identified = known.identify(saved.read)
        if let refusal = identified.refusal {
            log.log("\(chip): \(refusal)")
        } else if let version = identified.version {
            log.log("\(chip): firmware \(version)\(identified.ours ? ", ours" : "")\(Self.number(saved.read))")
        }
        log.log("\(chip): backup saved, read twice and the same (\(saved.files.count) files)")
        return Result(identified: identified, files: saved.files, read: saved.read)
    }

    private func refused(_ reason: String) -> Result {
        log.log("LC6000: no backup: \(reason)")
        return Result(refusal: reason)
    }

    /// The number the version was known by: the display chip's CRC (the top panel's hash is long, and adds nothing).
    private static func number(_ read: ChipRead) -> String {
        guard read.kind == .display, let crc = DisplayTrailer.crc(of: read.app) else { return "" }
        return String(format: ", CRC 0x%08X", crc)
    }
}
