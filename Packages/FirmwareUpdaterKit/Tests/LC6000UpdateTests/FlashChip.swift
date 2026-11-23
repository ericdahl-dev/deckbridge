import Foundation
import UnitCheck

/// A chip in ST's update mode with flash that can be erased and written, as DfuSe does it: command 0x41 erases the
/// sector at an address (to 0xFF), 0x21 sets the pointer, DNLOAD blocks from 2 program from it (bits only clear, so an
/// unerased write reads back wrong), UPLOAD blocks read. Made-up bytes. It records every request it got.
final class FlashChip: DFUTransport, @unchecked Sendable {
    let lock = NSLock()
    let base: UInt32 = 0x0800_0000
    private(set) var flash: [UInt8]
    private(set) var requests: [DFURequest] = []
    let sectors: [(UInt32, Int)]
    /// Stops answering after this many erases (nil: never): the chip no longer answers.
    var goneAfterErases: Int?
    /// A bit at this address that never programs: the read-back differs there (nil: none).
    var stuckAt: UInt32?
    private var erases = 0
    private var gone = false
    private var state: UInt8 = 2
    private var busy = false
    private var pointer: UInt32 = 0x0800_0000

    init(flash: [UInt8], sectors: [(UInt32, Int)]) {
        self.flash = flash
        self.sectors = sectors
    }

    var log: [DFURequest] { lock.withLock { requests } }

    /// The bytes from `address`, `length` long.
    func bytes(_ address: UInt32, _ length: Int) -> [UInt8] {
        lock.withLock { Array(flash[Int(address - base)..<(Int(address - base) + length)]) }
    }

    struct Gone: Error {}

    func control(_ r: DFURequest) async throws -> [UInt8] {
        try lock.withLock {
            requests.append(r)
            if gone { throw Gone() }
            switch (r.requestType, r.request) {
            case (0x21, 1) where r.value == 0 && r.data.count == 5:
                let address = UInt32(r.data[1]) | UInt32(r.data[2]) << 8 | UInt32(r.data[3]) << 16 | UInt32(r.data[4]) << 24
                if r.data[0] == 0x41 {
                    erases += 1
                    if let after = goneAfterErases, erases > after { gone = true; throw Gone() }
                    if let (start, length) = sectors.first(where: { $0.0 == address }) {
                        let from = Int(start - base)
                        flash.replaceSubrange(from..<(from + length), with: repeatElement(0xFF, count: length))
                    }
                } else if r.data[0] == 0x21 {
                    pointer = address
                }
                state = 4; busy = true
                return []
            case (0x21, 1) where r.value >= 2:
                let start = Int(pointer - base) + (Int(r.value) - 2) * 2048
                for (i, byte) in r.data.enumerated() {
                    var programmed = flash[start + i] & byte
                    if let stuck = stuckAt, Int(stuck - base) == start + i { programmed |= 0x01 }
                    flash[start + i] = programmed
                }
                state = 4; busy = true
                return []
            case (0xA1, 3):
                if busy { busy = false; state = 5; return [0, 0, 0, 0, 4, 0] }
                return [0, 0, 0, 0, state, 0]
            case (0x21, 4), (0x21, 6): state = 2; return []
            case (0xA1, 5): return [state]
            case (0xA1, 2):
                state = 9
                let start = Int(pointer - base) + (Int(r.value) - 2) * Int(r.length)
                let end = min(start + Int(r.length), flash.count)
                return start < end ? Array(flash[start..<end]) : []
            default:
                return []
            }
        }
    }
}
