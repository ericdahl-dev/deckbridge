import Testing
import UnitCheck

/// Made-up images, never Denon's. The wd one carries the trailer dfupatch.py checks: 0xDEADBEEF, the covered length,
/// the STM32 CRC, EndOfFlashToken. Its CRC, 0x3D498706, was computed by dfupatch.py's stm32_crc, not by this code.
func madeUpDisplayApp() -> [UInt8] {
    let size = 0x7_8000
    var app = (0..<size).map { UInt8(($0 * 7 + 3) % 251) }
    func put(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { app[offset + i] = UInt8(value >> (8 * UInt32(i)) & 0xFF) }
    }
    put(0xFFFF_FFFF, at: size - 32)
    put(0xDEAD_BEEF, at: size - 28)
    put(UInt32(size - 20), at: size - 24)
    put(0x3D49_8706, at: size - 20)
    app.replaceSubrange((size - 16)..., with: Array("EndOfFlashToken\u{0}".utf8))
    return app
}

/// Its SHA-256, 1690740c…58f5, from Python's hashlib.
func madeUpTopPanelApp() -> [UInt8] { (0..<0x3_8000).map { UInt8(($0 * 5 + 1) % 253) } }
let madeUpTopPanelHash = "1690740c65b2e35b665de01d13b2be1375e822a25466c0c602ecd1f7107a58f5"

let known = KnownFirmware(display: [0x3D49_8706: "00.50"], topPanel: [madeUpTopPanelHash: "00.31"])

@Suite("Unit check: which firmware a chip runs")
struct VersionTests {
    @Test("Display chip: the version from the read's own trailer CRC")
    func displayVersion() {
        let found = known.identify(ChipRead(kind: .display, settings: [], app: madeUpDisplayApp()))
        #expect(found.version == "00.50")
        #expect(found.refusal == nil)
    }

    @Test("Top panel chip: the version from the read's SHA-256")
    func topPanelVersion() {
        let found = known.identify(ChipRead(kind: .topPanel, settings: [], app: madeUpTopPanelApp()))
        #expect(found.version == "00.31")
        #expect(found.refusal == nil)
    }

    @Test("A version the app doesn't know: updates refused with a plain reason, the backup still allowed")
    func unknownVersion() {
        let none = KnownFirmware(display: [:], topPanel: [:])
        let display = none.identify(ChipRead(kind: .display, settings: [], app: madeUpDisplayApp()))
        #expect(display.version == nil)
        #expect(display.refusal == "The display chip runs firmware this app doesn't know (CRC 0x3D498706). Updates are off; a backup is still allowed.")
        #expect(display.backupAllowed)
        let topPanel = none.identify(ChipRead(kind: .topPanel, settings: [], app: madeUpTopPanelApp()))
        #expect(topPanel.version == nil)
        #expect(topPanel.refusal == "The top panel chip runs firmware this app doesn't know. Updates are off; a backup is still allowed.")
        #expect(topPanel.backupAllowed)
    }

    @Test("A display read that fails its own trailer CRC: may be damaged, updates refused, the backup still allowed")
    func damagedDisplay() {
        var app = madeUpDisplayApp()
        app[0x1000] ^= 0x01
        let found = known.identify(ChipRead(kind: .display, settings: [], app: app))
        #expect(found.version == nil)
        #expect(found.refusal == "The display chip's firmware doesn't match its own CRC, so it may be damaged. Updates are off; a backup is still allowed.")
        #expect(found.backupAllowed)
    }
}

@Suite("Unit check: our firmware already there")
struct OursTests {
    @Test("A read that matches one of our patched images says so, with the version it was built on")
    func oursAlreadyThere() {
        let table = KnownFirmware(display: [0x3A7C_E2CA: "00.50"], topPanel: [:],
                                  displayOurs: [0x3D49_8706: "00.50"], topPanelOurs: [madeUpTopPanelHash: "00.31"])
        let display = table.identify(ChipRead(kind: .display, settings: [], app: madeUpDisplayApp()))
        #expect(display.version == "00.50")
        #expect(display.ours)
        #expect(display.refusal == nil)
        let topPanel = table.identify(ChipRead(kind: .topPanel, settings: [], app: madeUpTopPanelApp()))
        #expect(topPanel.version == "00.31")
        #expect(topPanel.ours)
    }

    @Test("Stock firmware isn't ours")
    func stockIsNotOurs() {
        let display = known.identify(ChipRead(kind: .display, settings: [], app: madeUpDisplayApp()))
        #expect(!display.ours)
    }
}
