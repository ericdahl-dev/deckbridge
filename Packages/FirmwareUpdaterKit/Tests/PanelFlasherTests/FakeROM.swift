import Foundation
@testable import PanelFlasher

/// A deck panel's ESP32-S3 behind the CrowPanel's auto-reset circuit, as the flasher sees it over the cable (#687).
/// The circuit (two transistors, as on Espressif's devkits): EN is low only when RTS is on and DTR off; IO0 is low only
/// when DTR is on and RTS off. When EN rises, the chip boots into its ROM bootloader if IO0 is low, else into its app.
/// Its own SLIP decoding, written apart from the flasher's.
actor FakeROM: BootloaderLine {
    enum Mode: Equatable { case app, reset, download }

    private(set) var mode: Mode = .app
    private(set) var dtr = false, rts = false
    private(set) var resets = 0
    private(set) var received: [(op: UInt8, data: [UInt8], checksum: UInt32)] = []
    private var pending: [UInt8] = []
    private var incoming: [UInt8] = []
    /// Whether the chip answers at all (false: no ESP32 on the line, or a board without the auto-reset circuit).
    var answers = true
    /// Called after each reset into the ROM, to cancel a test's task mid-connect.
    var afterReset: (@Sendable () -> Void)?

    func setAfterReset(_ f: @escaping @Sendable () -> Void) { afterReset = f }
    func setAnswers(_ on: Bool) { answers = on }

    func setLines(dtr: Bool, rts: Bool) async throws {
        let wasLow = enLow
        self.dtr = dtr
        self.rts = rts
        if enLow { mode = .reset } else if wasLow {
            mode = io0Low ? .download : .app
            if mode == .download { resets += 1; afterReset?() }
        }
    }

    private var enLow: Bool { rts && !dtr }
    private var io0Low: Bool { dtr && !rts }

    func write(_ bytes: [UInt8]) async throws {
        incoming += bytes
        while let start = incoming.firstIndex(of: 0xC0), let end = incoming[(start + 1)...].firstIndex(of: 0xC0) {
            var frame: [UInt8] = []
            var i = start + 1
            while i < end {
                if incoming[i] == 0xDB { frame.append(incoming[i + 1] == 0xDC ? 0xC0 : 0xDB); i += 2 } else { frame.append(incoming[i]); i += 1 }
            }
            incoming.removeSubrange(start...end)
            if frame.count >= 8 { handle(frame) }
        }
    }

    private func handle(_ frame: [UInt8]) {
        let op = frame[1]
        let checksum = UInt32(frame[4]) | UInt32(frame[5]) << 8 | UInt32(frame[6]) << 16 | UInt32(frame[7]) << 24
        received.append((op, Array(frame[8...]), checksum))
        guard answers, mode == .download else { return }
        if op == 0x08 {
            // The ROM answers SYNC eight times, with a non-zero value.
            for _ in 0..<8 { reply(op: op, value: 0x2012_0707, data: []) }
        }
    }

    /// A ROM reply: data, status 00 00, then the two reserved bytes.
    private func reply(op: UInt8, value: UInt32, data: [UInt8], status: UInt8 = 0, reason: UInt8 = 0) {
        let body = data + [status, reason, 0, 0]
        var frame: [UInt8] = [0x01, op, UInt8(body.count & 0xFF), UInt8(body.count >> 8)]
        frame += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) } + body
        pending.append(0xC0)
        for b in frame {
            if b == 0xC0 { pending += [0xDB, 0xDC] } else if b == 0xDB { pending += [0xDB, 0xDD] } else { pending.append(b) }
        }
        pending.append(0xC0)
    }

    func read(timeout: Double) async throws -> [UInt8] {
        let out = pending
        pending = []
        return out
    }

    func setSpeed(_ baud: Int) async throws {}
    func pause(_ seconds: Double) async { await Task.yield() }

    var ops: [UInt8] { received.map(\.op) }
}
