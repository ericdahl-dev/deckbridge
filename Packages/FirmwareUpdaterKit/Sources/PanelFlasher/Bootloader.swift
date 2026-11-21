/// The serial line to a deck panel, as the flasher drives it. The app's adapter is the real port.
public protocol BootloaderLine: Sendable {
    /// Sets DTR and RTS together, in one call.
    func setLines(dtr: Bool, rts: Bool) async throws
    func write(_ bytes: [UInt8]) async throws
    /// Whatever arrived within `timeout` seconds.
    func read(timeout: Double) async throws -> [UInt8]
    func setSpeed(_ baud: Int) async throws
    func pause(_ seconds: Double) async
}

public enum FlashError: Error, Equatable {
    /// Nothing answered the bootloader's SYNC after every reset: no ESP32 on the line, or no auto-reset circuit.
    case noBootloader
}

/// The ESP32-S3's ROM serial bootloader on a deck panel, reached through the CrowPanel's auto-reset circuit (#687).
/// Whatever happens (a failure, the owner cancelling), the panel is left running its app: both lines off.
public actor Bootloader {
    let line: any BootloaderLine
    private var reader = SlipReader()

    /// esptool's defaults (loader.py): 7 connect attempts of a reset then up to 5 SYNCs, each read for 0.1 s.
    static let attempts = 7, syncsPerAttempt = 5, syncTimeout = 0.1
    /// esptool's DEFAULT_RESET_DELAY: the chip's time to come out of reset before the first SYNC.
    static let resetDelay = 0.05

    public init(line: any BootloaderLine) { self.line = line }

    /// Resets the panel into its ROM bootloader and syncs with it, as esptool does on a Mac (UnixTightReset: DTR and RTS
    /// set together, so the circuit never sees one move alone). On failure or cancellation the panel is released.
    public func connect() async throws {
        do {
            for _ in 0..<Self.attempts {
                try Task.checkCancellation()
                try await resetIntoBootloader()
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

    /// Resets the panel into its app: EN low with IO0 high, then both lines off (esptool's HardReset). Never throws:
    /// it runs on every way out.
    public func release() async {
        try? await line.setLines(dtr: false, rts: true)
        await line.pause(0.1)
        try? await line.setLines(dtr: false, rts: false)
    }

    private func resetIntoBootloader() async throws {
        try await line.setLines(dtr: false, rts: false)
        try await line.setLines(dtr: true, rts: true)
        try await line.setLines(dtr: false, rts: true)  // IO0 high, EN low: in reset
        await line.pause(0.1)
        try await line.setLines(dtr: true, rts: false)  // IO0 low, EN high: out of reset into the ROM
        await line.pause(Self.resetDelay)
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
