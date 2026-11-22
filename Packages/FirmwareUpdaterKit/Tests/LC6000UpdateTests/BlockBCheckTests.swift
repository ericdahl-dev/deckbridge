import DeviceFinder
import Foundation
import LC6000Update
import Testing

/// Before block B goes on (#751), reads only: the display chip runs our hook and a block A this app knows, built to
/// call B, with the layout B was built for. Made-up bytes; the A fixtures' sha1s are Python's.
@Suite("Block B: the check before it's installed")
struct BlockBCheckTests {
    final class Lines: LogSink, @unchecked Sendable {
        var lines: [String] = []
        func log(_ line: String) { lines.append(line) }
    }

    /// The display chip's app area (0x08008000, 480 KB) with block A, filled with `fill`, in the padding at 0x0807DC00
    /// and our marker "DFW1" last at 0x0807FFDC, unless `hooked` is false.
    static func app(a fill: UInt8 = 0x11, hooked: Bool = true) -> [UInt8] {
        var app = [UInt8](repeating: 0x5A, count: 0x7_8000)
        let a = 0x0807_DC00 - 0x0800_8000
        for i in 0..<9184 { app[a + i] = fill }
        if hooked { for (i, byte) in [UInt8(0x44), 0x46, 0x57, 0x31].enumerated() { app[a + 9180 + i] = byte } }
        return app
    }

    static let aSHA1 = "91e9aa2503c0f93331279aad8869238092dacbaa"  // app(a: 0x11)'s block A
    static let otherSHA1 = "18833d375daa12de542bd201b3cef76140ae01f1"  // app(a: 0x22)'s

    static func b(layout: UInt32 = 0x0055_B470) throws -> BlockB {
        let v = try BlockBTests.vectors().cases.first { !$0.refused }!
        var bytes = BlockBTests.bytes(v.block_hex)
        guard layout != 0x0055_B470 else { return try BlockB(bytes) }
        // Another layout: rewrite +16 and reseal the CRC as upper_header.py's seal does.
        for i in 0..<4 { bytes[16 + i] = UInt8(layout >> (8 * UInt32(i)) & 0xFF) }
        let crc = BlockBTests.zlibCRC(bytes[16...])
        for i in 0..<4 { bytes[12 + i] = UInt8(crc >> (8 * UInt32(i)) & 0xFF) }
        return try BlockB(bytes)
    }

    static let known = [
        KnownBlockA(sha1: aSHA1, layout: 0x0055_B470, callsB: true, from: "a test"),
        KnownBlockA(sha1: otherSHA1, layout: 0x0055_B470, callsB: false, from: "a test"),
    ]

    @Test("Our hook, a known A that calls B, and B's layout: ready")
    func ready() throws {
        let log = Lines()
        #expect(BlockBCheck.check(app: Self.app(), b: try Self.b(), known: Self.known, log: log) == .ready)
    }

    @Test("No hook (stock, or another image): refused, nothing would ever call B")
    func noHook() throws {
        let result = BlockBCheck.check(app: Self.app(hooked: false), b: try Self.b(), known: Self.known, log: Lines())
        #expect(result == .refused("The display chip doesn't carry DeckBridge's block A, so nothing would ever call block B. Install the display chip's image first."))
    }

    @Test("An A this app doesn't know: refused, and its sha1 is shown and logged, for the table")
    func unknownA() throws {
        let log = Lines()
        let result = BlockBCheck.check(app: Self.app(a: 0x33), b: try Self.b(), known: Self.known, log: log)
        guard case .refused(let reason) = result else { Issue.record("not refused"); return }
        #expect(reason.hasPrefix("Block A on the display chip isn't one this app knows (sha1 "))
        #expect(log.lines.count == 1)
        #expect(log.lines.first?.hasPrefix("display chip: block A sha1 ") == true)
        #expect(log.lines.first?.hasSuffix(", not one this app knows; block B not installed") == true)
        // The same sha1 in both, 40 hex digits.
        let shown = reason.split(separator: " ").first { $0.count == 41 && $0.hasSuffix(")") }.map { String($0.dropLast()) }
        #expect(shown?.count == 40)
        #expect(log.lines.first?.contains(shown ?? "none") == true)
    }

    @Test("A known A built never to call B: refused, installing B would change nothing")
    func neverCallsB() throws {
        let result = BlockBCheck.check(app: Self.app(a: 0x22), b: try Self.b(), known: Self.known, log: Lines())
        #expect(result == .refused("Block A on the display chip was built never to call block B, so installing B would change nothing. Install the display chip's image first."))
    }

    @Test("A known A with another layout: refused, naming both words")
    func layoutMismatch() throws {
        let result = BlockBCheck.check(app: Self.app(), b: try Self.b(layout: 0x0012_3456), known: Self.known, log: Lines())
        #expect(result == .refused("Block A on the display chip has layout 0x0055B470 and this block B is built for 0x00123456: they're from different builds. Install the display chip's image and block B from the same build."))
    }

    @Test("The shipped table: the two block A builds (the first confirmed on the owner's unit)")
    func shippedTable() {
        #expect(KnownBlockA.shipped.map(\.sha1) == ["07da7ec9198ec9b22ac02ff143355dcbf2b44347", "9db1e172b34b5775d073d5013d77b15e6840b9e8"])
        #expect(KnownBlockA.shipped.map(\.callsB) == [true, false])
        #expect(KnownBlockA.shipped[0].layout == 0x0055_B470)
    }
}

extension BlockBTests {
    /// zlib's CRC-32, for resealing a test B (Python's zlib.crc32 made the vectors; this is only for a changed layout).
    static func zlibCRC(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
