import CryptoKit
import Foundation

/// The serial line to a deck panel, as the flasher drives it. The app's adapter is the real port.
public protocol BootloaderLine: Sendable {
    /// Sets DTR and RTS together, in one call.
    func setLines(dtr: Bool, rts: Bool) async throws
    func write(_ bytes: [UInt8]) async throws
    /// Whatever arrived within `timeout` seconds.
    func read(timeout: Double) async throws -> [UInt8]
    func setSpeed(_ baud: Int) async throws
    /// Waits `seconds`, the whole time even in a cancelled task: the reset pulse that leaves the panel running is
    /// timed with it, and cutting it short can leave the chip in its bootloader (embedded review, #687).
    func pause(_ seconds: Double) async
    /// Closes the port. The line is unusable after.
    func close() async
}

public enum FlashError: Error, Equatable {
    /// Nothing answered the bootloader's SYNC after every reset: no ESP32 on the line, or no auto-reset circuit.
    case noBootloader
    /// Not a deck panel's chip, an ESP32-S3; the text says what it is.
    case wrongBoard(String)
    /// The ROM refused a command: its op and the ROM's reason byte.
    case refused(op: UInt8, reason: UInt8)
    /// The ROM didn't answer a command in time.
    case noAnswer(op: UInt8)
    /// The chip kept refusing the block at this flash address.
    case writeFailed(address: UInt32)
    /// What the flash holds at this address isn't the image that was written.
    case verifyFailed(address: UInt32)
    /// An ESP32-S3 without the deck panel's partition table: blank, or another board's layout.
    case notADeckPanel
    /// Another app holds the panel's cable: DeckBridge, sending over it.
    case portBusy
    /// The owner cancelled; the panel was reset into its app.
    case cancelled
    /// The owner cancelled after writing began: the panel was reset, but what it boots may be half written.
    case cancelledWhileWriting
    /// The line itself failed: the cable came out, or the port went away.
    case lineLost
    /// The image to write isn't an ESP32-S3 app image that fits app0.
    case notAPanelImage
}

/// The ESP32-S3's ROM serial bootloader on a deck panel, reached through the CrowPanel's auto-reset circuit (#687).
/// Whatever happens (a failure, the owner cancelling), the panel is left running its app: both lines off.
public actor Bootloader {
    let line: any BootloaderLine
    private var reader = SlipReader()

    /// esptool's defaults (loader.py): 7 connect attempts of a reset then up to 5 SYNCs, each read for 0.1 s.
    static let attempts = 7, syncsPerAttempt = 5, syncTimeout = 0.1
    /// The chip's time to come out of reset before the first SYNC, alternating as esptool's connect does
    /// (DEFAULT_RESET_DELAY 0.05 s, then 0.55 s for slower EN circuits).
    static let resetDelays = [0.05, 0.55]

    public init(line: any BootloaderLine) { self.line = line }

    /// Resets the panel into its ROM bootloader and syncs with it, as esptool does on a Mac (UnixTightReset: DTR and RTS
    /// set together, so the circuit never sees one move alone). On failure or cancellation the panel is released.
    public func connect() async throws {
        do {
            for attempt in 0..<Self.attempts {
                try Task.checkCancellation()
                try await resetIntoBootloader(delay: Self.resetDelays[attempt % Self.resetDelays.count])
                for _ in 0..<Self.syncsPerAttempt {
                    try Task.checkCancellation()
                    if try await sync() { return }
                }
            }
            throw FlashError.noBootloader
        } catch {
            await release()
            throw error
        }
    }

    /// Whether the panel was reset into its app since the lines last moved toward the ROM: release() pulses once.
    private var released = true

    /// Resets the panel into its app: EN low with IO0 high, then both lines off (esptool's HardReset). Never throws:
    /// it runs on every way out, and only the first call after a reset into the ROM pulses the lines.
    public func release() async {
        guard !released else { return }
        released = true
        try? await line.setLines(dtr: false, rts: true)
        await line.pause(0.1)
        try? await line.setLines(dtr: false, rts: false)
    }

    /// GET_SECURITY_INFO's chip id for an ESP32-S3 (esptool targets/esp32s3.py IMAGE_CHIP_ID).
    static let esp32S3 = UInt32(9)

    /// Refuses anything but an ESP32-S3, before anything is written: GET_SECURITY_INFO's chip id (the word after the
    /// flags, crypt count and seven key purposes). A ROM without the command, the original ESP32's, refuses it.
    public func checkChip() async throws {
        do {
            let info: Response
            do {
                // 20 bytes on an S3, 12 on an S2 (esptool tries both): taken as the ROM sends it.
                info = try await command(.securityInfo, data: [], dataLength: nil)
            } catch FlashError.refused(_, _) {
                throw FlashError.wrongBoard("an ESP32 without GET_SECURITY_INFO")
            }
            guard info.data.count != 12 else { throw FlashError.wrongBoard("an ESP32-S2") }
            guard info.data.count >= 20 else { throw FlashError.wrongBoard("an unknown chip") }
            let word = { (at: Int) in
                UInt32(info.data[at]) | UInt32(info.data[at + 1]) << 8 | UInt32(info.data[at + 2]) << 16 | UInt32(info.data[at + 3]) << 24
            }
            let id = word(12)
            guard id == Self.esp32S3 else { throw FlashError.wrongBoard("chip id \(id)") }
            // SECURE_BOOT_EN (bit 0), SECURE_DOWNLOAD_ENABLE (bit 2), and flash encryption on when flash_crypt_cnt has
            // an odd number of bits set: plain bytes written then wouldn't boot.
            let flags = word(0), cryptCount = info.data[4]
            guard flags & 0b101 == 0, cryptCount.nonzeroBitCount % 2 == 0 else {
                throw FlashError.wrongBoard("an ESP32-S3 with secure boot or flash encryption on")
            }
        } catch {
            await release()
            throw error
        }
    }

    /// The panel's upload speed (tools/deck-panel/platformio.ini upload_speed); the ROM starts at 115200.
    public static let fastSpeed = 921_600

    /// Moves both ends to 921600, as esptool's change_baud does on the ROM: CHANGE_BAUDRATE (new speed, 0), answered
    /// at the old speed; then the Mac's line, a 0.05 s wait, and whatever arrived in the change is dropped.
    public func speedUp() async throws {
        do {
            _ = try await command(.changeSpeed, data: Packet.le32(UInt32(Self.fastSpeed)) + Packet.le32(0))
            try await line.setSpeed(Self.fastSpeed)
            await line.pause(0.05)
            _ = try await line.read(timeout: 0)
            reader = SlipReader()
        } catch {
            await release()
            throw error
        }
    }

    /// The ROM's flash block (esptool FLASH_WRITE_SIZE), how often a refused block is tried (WRITE_BLOCK_ATTEMPTS),
    /// and the panel's flash, 16 MB (platformio.ini board_upload.flash_size).
    static let blockSize = 0x400, blockAttempts = 3, flashSize = UInt32(16 * 1024 * 1024)
    private var flashReady = false
    /// Whether any FLASH_BEGIN has been sent: from then on the flash may hold a half-written region.
    public private(set) var hasWritten = false

    /// Writes `image` at `offset`, as esptool's write_flash does on the ROM (no stub, no compression): SPI_ATTACH and
    /// SPI_SET_PARAMS once, then FLASH_BEGIN (which erases), then FLASH_DATA blocks padded with FF, each with the ROM's
    /// checksum. `progress` gets the share written after each block. On failure the panel is released.
    public func write(_ image: [UInt8], at offset: UInt32, progress: @Sendable (Double) -> Void) async throws {
        do {
            try await prepareFlash()
            let padded = image + [UInt8](repeating: 0xFF, count: (4 - image.count % 4) % 4)
            let blocks = (padded.count + Self.blockSize - 1) / Self.blockSize
            hasWritten = true
            // Erasing takes the ROM a while: esptool allows 30 s per MB (ERASE_REGION_TIMEOUT_PER_MB).
            _ = try await command(.flashBegin, data: Packet.le32(UInt32(padded.count)) + Packet.le32(UInt32(blocks))
                                  + Packet.le32(UInt32(Self.blockSize)) + Packet.le32(offset) + Packet.le32(0),
                                  timeout: max(3, 30 * Double(padded.count) / 1_000_000))
            for seq in 0..<blocks {
                var block = Array(padded[(seq * Self.blockSize)..<min(padded.count, (seq + 1) * Self.blockSize)])
                block += [UInt8](repeating: 0xFF, count: Self.blockSize - block.count)
                let data = Packet.le32(UInt32(block.count)) + Packet.le32(UInt32(seq)) + Packet.le32(0) + Packet.le32(0) + block
                try await sendBlock(data, checksum: Self.checksum(block), address: offset + UInt32(seq * Self.blockSize))
                progress(Double(seq + 1) / Double(blocks))
            }
        } catch {
            await release()
            throw error
        }
    }

    /// Checks the flash holds `image` at `offset`: the chip's own MD5 of that region (SPI_FLASH_MD5, which the ROM
    /// answers with 32 hex characters) against the image's, padded to 4 bytes as it was written. On failure the panel
    /// is released.
    public func verify(_ image: [UInt8], at offset: UInt32) async throws {
        do {
            let padded = image + [UInt8](repeating: 0xFF, count: (4 - image.count % 4) % 4)
            let expected = Insecure.MD5.hash(data: Data(padded)).map { String(format: "%02x", $0) }.joined()
            guard try await flashMD5(at: offset, size: padded.count) == expected else {
                throw FlashError.verifyFailed(address: offset)
            }
        } catch {
            await release()
            throw error
        }
    }

    /// The deck panel's partitions (tools/deck-panel/partitions.csv).
    public enum Partition {
        public static let nvs = (offset: UInt32(0x9000), size: 0x5000)
        public static let otadata = (offset: UInt32(0xE000), size: 0x2000)
        public static let app0 = UInt32(0x10000)
    }

    /// Arduino-ESP32's boot_app0.bin, which every `pio upload` writes at otadata: the first entry sequence 1 with its
    /// CRC (0x4743989A); the second sequence 0, whose CRC is FFFFFFFF (crc32_le(0xFFFFFFFF) of 0 is that, so it is a
    /// valid entry). The higher sequence wins: (1 - 1) % 2 = slot 0, app0. Built here byte for byte.
    static let bootApp0: [UInt8] = {
        var bytes = [UInt8](repeating: 0xFF, count: Partition.otadata.size)
        bytes.replaceSubrange(0..<4, with: [0x01, 0x00, 0x00, 0x00])
        bytes.replaceSubrange(0x1C..<0x20, with: [0x9A, 0x98, 0x43, 0x47])
        bytes.replaceSubrange(0x1000..<0x1004, with: [0x00, 0x00, 0x00, 0x00])
        return bytes
    }()

    /// Puts a deck panel app on the panel the way `pio upload` does: the image at app0, verified, then boot_app0 at
    /// otadata, so app0 boots even on a panel an update over Wi-Fi left on app1 (#690). Saved Wi-Fi in nvs is kept
    /// unless the owner asks to wipe it; app1, spiffs and coredump are never touched. `progress` follows the app.
    public func flashApp(_ image: [UInt8], wipeWiFi: Bool, progress: @Sendable (Double) -> Void) async throws {
        try await write(image, at: Partition.app0, progress: progress)
        try await verify(image, at: Partition.app0)
        try await write(Self.bootApp0, at: Partition.otadata.offset) { _ in }
        try await verify(Self.bootApp0, at: Partition.otadata.offset)
        if wipeWiFi {
            let erased = [UInt8](repeating: 0xFF, count: Partition.nvs.size)
            try await write(erased, at: Partition.nvs.offset) { _ in }
            try await verify(erased, at: Partition.nvs.offset)
        }
    }

    /// The deck panel's partition table at 0x8000, 3,072 bytes: the MD5 of what gen_esp32part.py writes from
    /// tools/deck-panel/partitions.csv.
    static let partitionTable = (offset: UInt32(0x8000), size: 3072, md5: "118cbdbfce82eb12bbdeb7c59af2fce8")

    /// Refuses a board whose flash doesn't hold the deck panel's partition table, before anything is written: the
    /// chip's MD5 of the table's region against ours.
    public func checkPartitionTable(_ expected: [UInt8]? = nil) async throws {
        do {
            guard try await isDeckPanel(expected) else { throw FlashError.notADeckPanel }
        } catch {
            await release()
            throw error
        }
    }

    /// Whether the board holds the deck panel's partition table: `expected` (the panel build's own, from the
    /// catalog) or, without one, gen_esp32part.py's from partitions.csv. Leaves the panel in its bootloader.
    public func isDeckPanel(_ expected: [UInt8]? = nil) async throws -> Bool {
        try await prepareFlash()
        let ours = expected.map { Insecure.MD5.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
            ?? Self.partitionTable.md5
        return try await flashMD5(at: Self.partitionTable.offset, size: Self.partitionTable.size) == ours
    }

    /// Makes a blank or foreign ESP32-S3 a deck panel, writing what `pio upload` writes: the bootloader at 0x0, the
    /// partition table at 0x8000, the app at app0 and boot_app0 at otadata, each verified. nvs is wiped: what a foreign
    /// board kept there isn't the panel's.
    public func makeDeckPanel(_ image: [UInt8], bootloader: [UInt8], partitions: [UInt8],
                              progress: @Sendable (Double) -> Void) async throws {
        try await write(bootloader, at: 0x0) { _ in }
        try await verify(bootloader, at: 0x0)
        try await write(partitions, at: Self.partitionTable.offset) { _ in }
        try await verify(partitions, at: Self.partitionTable.offset)
        try await flashApp(image, wipeWiFi: true, progress: progress)
    }

    /// The chip's MD5 of `size` bytes of flash at `offset` (SPI_FLASH_MD5: the ROM answers with 32 hex characters).
    /// esptool allows 8 s per MB (MD5_TIMEOUT_PER_MB).
    private func flashMD5(at offset: UInt32, size: Int) async throws -> String {
        let answer = try await command(.flashMD5, data: Packet.le32(offset) + Packet.le32(UInt32(size)) + Packet.le32(0)
                                       + Packet.le32(0), dataLength: 32, timeout: max(3, 8 * Double(size) / 1_000_000))
        return String(decoding: answer.data, as: UTF8.self).lowercased()
    }

    private func prepareFlash() async throws {
        guard !flashReady else { return }
        _ = try await command(.spiAttach, data: Packet.le32(0) + [0, 0, 0, 0])
        _ = try await command(.spiSetParams, data: Packet.le32(0) + Packet.le32(Self.flashSize) + Packet.le32(64 * 1024)
                              + Packet.le32(4 * 1024) + Packet.le32(256) + Packet.le32(0xFFFF))
        flashReady = true
    }

    private func sendBlock(_ data: [UInt8], checksum: UInt32, address: UInt32) async throws {
        for attempt in 1...Self.blockAttempts {
            do {
                _ = try await command(.flashData, data: data, checksum: checksum)
                return
            } catch FlashError.refused(_, _) where attempt < Self.blockAttempts {
                continue
            } catch FlashError.refused(_, _), FlashError.noAnswer(_) {
                throw FlashError.writeFailed(address: address)
            }
        }
    }

    /// The ROM's checksum of a block: 0xEF xor every byte (esptool ESP_CHECKSUM_MAGIC).
    static func checksum(_ block: [UInt8]) -> UInt32 {
        var state: UInt8 = 0xEF
        for byte in block { state ^= byte }
        return UInt32(state)
    }

    /// Sends one command and waits for its answer: `dataLength` bytes of data, then the status.
    func command(_ op: Op, data: [UInt8], checksum: UInt32 = 0, dataLength: Int? = 0, timeout: Double = 3) async throws -> Response {
        try Task.checkCancellation()
        try await line.write(Packet.command(op, data: data, checksum: checksum))
        // Wall-clock time, not a count of reads: a read returns as soon as anything arrives, stray frames included.
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            let left = (deadline - ContinuousClock.now).components
            let seconds = Double(left.seconds) + Double(left.attoseconds) / 1e18
            for frame in reader.feed(try await line.read(timeout: min(0.1, max(0, seconds)))) {
                guard let response = Packet.response(frame, dataLength: dataLength), response.op == op.rawValue else { continue }
                guard response.ok else { throw FlashError.refused(op: op.rawValue, reason: response.error) }
                return response
            }
            try Task.checkCancellation()
        }
        throw FlashError.noAnswer(op: op.rawValue)
    }

    private func resetIntoBootloader(delay: Double) async throws {
        released = false  // before any line moves: a failure from here on must still release the panel
        try await line.setLines(dtr: false, rts: false)
        try await line.setLines(dtr: true, rts: true)
        try await line.setLines(dtr: false, rts: true)  // IO0 high, EN low: in reset
        await line.pause(0.1)
        try await line.setLines(dtr: true, rts: false)  // IO0 low, EN high: out of reset into the ROM
        await line.pause(delay)
        try await line.setLines(dtr: false, rts: false)  // IO0 high again
        _ = try await line.read(timeout: 0)  // the ROM's boot text
        reader = SlipReader()
    }

    /// One SYNC; true when the ROM answered it. The ROM answers eight times: the rest are read and dropped.
    private func sync() async throws -> Bool {
        try await line.write(Packet.command(.sync, data: Packet.syncData))
        let frames = reader.feed(try await line.read(timeout: Self.syncTimeout))
        return frames.contains { Packet.response($0, dataLength: 0).map { $0.op == Op.sync.rawValue && $0.ok } ?? false }
    }
}
