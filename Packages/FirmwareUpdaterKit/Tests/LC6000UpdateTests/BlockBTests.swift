import Foundation
import LC6000Update
import Testing

/// Block B as the updater installs it (#751): checked the way block A checks it on the chip, against the kit's shared
/// vectors (tools/lc6000-firmware/upper_vectors.json, sealed by upper_header.py, synthetic).
@Suite("Block B: the checks before it's installed")
struct BlockBTests {
    struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let block_hex: String
            let refused: Bool
            let layout: String?
        }
        let address: String
        let cases: [Case]
    }

    static func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: PatchVectorTests.kit.appending(path: "upper_vectors.json")))
    }

    static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { i in
            UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)!
        }
    }

    @Test("The updater refuses exactly the shared vectors the kit refuses, and reads a sound B's layout word")
    func sharedVectors() throws {
        let v = try Self.vectors()
        #expect(v.cases.count >= 4)
        for c in v.cases {
            if c.refused {
                #expect(throws: BlockB.Refused.self, "\(c.name)") { try BlockB(Self.bytes(c.block_hex)) }
            } else {
                let b = try BlockB(Self.bytes(c.block_hex))
                #expect(b.layout == UInt32(c.layout!.dropFirst(2), radix: 16), "\(c.name)")
                #expect(b.bytes == Self.bytes(c.block_hex))
            }
        }
        #expect(BlockB.address == UInt32(v.address.dropFirst(2), radix: 16))
    }
}
