import CryptoKit
import FirmwareCatalog
import Foundation
import LC6000Update
import Testing
import UnitCheck

/// The patched image the app builds equals the flash kit's (dfupatch.py) for the kit's shared vectors (#693):
/// tools/lc6000-firmware/vectors.json, synthetic images only, with the SHA-256 the kit's own test pins.
@Suite("LC6000 update: the patched image matches the flash kit")
struct PatchVectorTests {
    static let kit = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../tools/lc6000-firmware")
        .standardized

    struct Vector: Decodable {
        struct Plant: Decodable { let at: String; let hex: String }
        let name: String
        let chip: String
        let size: String
        let fill: String
        var plant: [Plant]? = nil
        var after_trailer: [Plant]? = nil
        var patch_file: String? = nil
        var patch: String? = nil
        let sha256: String?
    }

    static func vectors() throws -> [Vector] {
        try JSONDecoder().decode([Vector].self, from: Data(contentsOf: kit.appending(path: "vectors.json")))
    }

    static func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map { i in
            let start = text.index(text.startIndex, offsetBy: i)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    /// The image a vector describes, as tools/lc6000-firmware/test_vectors.py builds it.
    static func element(_ v: Vector) -> [UInt8] {
        let size = Int(v.size.dropFirst(2), radix: 16)!
        let fill = hex(v.fill)
        var body = (0..<size).map { fill[$0 % fill.count] }
        for plant in v.plant ?? [] {
            let at = Int(UInt32(plant.at.dropFirst(2), radix: 16)! - PatchedImage.base)
            for (i, byte) in hex(plant.hex).enumerated() { body[at + i] = byte }
        }
        func put(_ value: UInt32, at: Int) { for i in 0..<4 { body[at + i] = UInt8(value >> (8 * UInt32(i)) & 0xFF) } }
        if v.chip == "wd" {
            body.replaceSubrange((size - 32)..<(size - 28), with: [0, 0, 5, 0])
            put(0xDEAD_BEEF, at: size - 28)
            put(UInt32(size - 20), at: size - 24)
            put(DisplayTrailer.stm32CRC(body[..<(size - 20)]), at: size - 20)
        }
        body.replaceSubrange((size - 16)..<size, with: Array("EndOfFlashToken\u{0}".utf8))
        for plant in v.after_trailer ?? [] {  // changed after the trailer was made: a stale CRC
            let at = Int(UInt32(plant.at.dropFirst(2), radix: 16)! - PatchedImage.base)
            for (i, byte) in hex(plant.hex).enumerated() { body[at + i] = byte }
        }
        return body
    }

    static func edits(_ v: Vector) throws -> [PatchEdit] {
        let data = try v.patch_file.map { try Data(contentsOf: kit.appending(path: $0)) } ?? Data(v.patch!.utf8)
        return try #require(PatchDescription.edits(data))
    }

    @Test("Each vector: the kit's SHA-256, or refused where the kit refuses")
    func vectorsMatchTheKit() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count >= 6)
        for v in vectors {
            let chip: Chip = v.chip == "wd" ? .wd : .tp
            let result = try? PatchedImage.apply(try Self.edits(v), chip: chip, to: Self.element(v))
            let sha = result.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            #expect(sha == v.sha256, "\(v.name)")
        }
    }
}
