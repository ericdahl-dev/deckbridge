import Foundation
import UnitCheck

/// A chip in ST's update mode, as far as a read needs: DfuSe set-address, UPLOAD blocks, GETSTATUS, CLRSTATUS,
/// ABORT. Its flash is made-up bytes. It records every request it got.
final class FakeChip: DFUTransport, @unchecked Sendable {
    let lock = NSLock()
    let base: UInt32
    let flash: [UInt8]
    private(set) var requests: [DFURequest] = []
    /// Leaves update mode after this many UPLOADs (nil: never).
    var leavesAfterUploads: Int?
    /// From this many UPLOADs on, every block's first byte reads flipped: a flaky read (nil: never).
    var flipsAfterUploads: Int?
    private var uploads = 0
    private var state: UInt8 = 2 // dfuIDLE
    private var pointer: UInt32
    private var busy = false

    init(base: UInt32 = 0x0800_0000, flash: [UInt8]) {
        self.base = base
        pointer = base
        self.flash = flash
    }

    init(base: UInt32 = 0x0800_0000, size: Int, seed: UInt64 = 0x5EED) {
        self.base = base
        pointer = base
        var x = seed
        flash = (0..<size).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: x >> 33)
        }
    }

    var log: [DFURequest] { lock.withLock { requests } }

    func control(_ r: DFURequest) async throws -> [UInt8] {
        try lock.withLock {
            requests.append(r)
            if let after = leavesAfterUploads, uploads >= after { throw DFUError.left }
            switch (r.requestType, r.request) {
            case (0x21, 1): // DNLOAD
                if r.value == 0, r.data.count == 5, r.data[0] == 0x21 {
                    pointer = UInt32(r.data[1]) | UInt32(r.data[2]) << 8 | UInt32(r.data[3]) << 16 | UInt32(r.data[4]) << 24
                }
                state = 4; busy = true // dfuDNBUSY until the next GETSTATUS
                return []
            case (0xA1, 3): // GETSTATUS
                if busy { busy = false; let s = state; state = 5; return [0, 0, 0, 0, s, 0] }
                return [0, 0, 0, 0, state, 0]
            case (0x21, 4): state = 2; return [] // CLRSTATUS
            case (0x21, 6): state = 2; return [] // ABORT
            case (0xA1, 5): return [state]       // GETSTATE
            case (0xA1, 2): // UPLOAD
                uploads += 1
                state = 9 // dfuUPLOAD_IDLE
                guard pointer >= base, r.value >= 2 else { return [] }
                let start = Int(pointer - base) + (Int(r.value) - 2) * Int(r.length)
                let end = min(start + Int(r.length), flash.count)
                var block = start < end ? Array(flash[start..<end]) : []
                if let after = flipsAfterUploads, uploads > after, !block.isEmpty { block[0] ^= 0xFF }
                return block
            default:
                return []
            }
        }
    }
}
