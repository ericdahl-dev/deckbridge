// Before block B goes on the display chip (#751), reads only: the chip's app area (the unit check's read, #709) must
// hold our hook's marker and a block A this app knows, built to call B, with the layout B was built for. Block A's
// layout lives in its code, not at an address (#751), so A is known by the sha1 of its 9,184 padding bytes.
import CryptoKit
import DeviceFinder
import Foundation

/// A block A build this app knows: its padding bytes' sha1, the layout it calls B with, and whether it calls B at all
/// (built with ARM_UPPER_PROVEN=1).
public struct KnownBlockA: Sendable, Equatable {
    public let sha1: String
    public let layout: UInt32
    public let callsB: Bool
    /// Where the entry came from, for whoever reads the table.
    public let from: String

    public init(sha1: String, layout: UInt32, callsB: Bool, from: String) {
        self.sha1 = sha1
        self.layout = layout
        self.callsB = callsB
        self.from = from
    }

    /// From the 11-19 image names (wd-upper-drawing-a9b985d, -5f7c0a13), before #573 made ARM_UPPER_PROVEN=1 the
    /// default: block A is byte-identical at a9b985d1,
    /// 5f7c0a13 and main ef0e5e6c for the same flag, built locally with Homebrew's arm-none-eabi-gcc 16.2.0. Candidates,
    /// not facts: an A that isn't here is refused with its sha1 logged, and added after the owner's run reads it.
    public static let shipped = [
        KnownBlockA(sha1: "07da7ec9198ec9b22ac02ff143355dcbf2b44347", layout: 0x0055_B470, callsB: true,
                    from: "a9b985d1, 5f7c0a13, ef0e5e6c with ARM_UPPER_PROVEN=1 (from 11-19 file names)"),
        KnownBlockA(sha1: "9db1e172b34b5775d073d5013d77b15e6840b9e8", layout: 0x0055_B470, callsB: false,
                    from: "a9b985d1, 5f7c0a13 with ARM_UPPER_PROVEN=0, their default (from 11-19 file names)"),
    ]
}

public enum BlockBCheck: Sendable, Equatable {
    case ready
    case refused(String)

    /// Block A's place in the display chip's app area (0x08008000): 0x0807DC00, 9,184 bytes, its marker "DFW1" last.
    static let appAddress: UInt32 = 0x0800_8000
    static let blockA = (address: UInt32(0x0807_DC00), length: 9184)
    static let hookMarker: [UInt8] = [0x44, 0x46, 0x57, 0x31]  // "DFW1", little-endian 0x31574644

    public static func check(app: [UInt8], b: BlockB, known: [KnownBlockA] = KnownBlockA.shipped,
                             log: any LogSink) -> BlockBCheck {
        let from = Int(blockA.address - appAddress), to = from + blockA.length
        guard app.count >= to, Array(app[(to - 4)..<to]) == hookMarker else {
            return .refused("The display chip doesn't carry DeckBridge's block A, so nothing would ever call block B. "
                            + "Install the display chip's image first.")
        }
        let sha1 = Insecure.SHA1.hash(data: Data(app[from..<to])).map { String(format: "%02x", $0) }.joined()
        guard let a = known.first(where: { $0.sha1 == sha1 }) else {
            log.log("display chip: block A sha1 \(sha1), not one this app knows; block B not installed")
            return .refused("Block A on the display chip isn't one this app knows (sha1 \(sha1))")
        }
        guard a.callsB else {
            return .refused("Block A on the display chip was built never to call block B, so installing B would change "
                            + "nothing. Install the display chip's image first.")
        }
        guard a.layout == b.layout else {
            return .refused("Block A on the display chip has layout \(hex(a.layout)) and this block B is built for "
                            + "\(hex(b.layout)): they're from different builds. Install the display chip's image and block B "
                            + "from the same build.")
        }
        return .ready
    }

    static func hex(_ value: UInt32) -> String { "0x" + String(format: "%08X", value) }
}
