import Testing
@testable import PanelFlasher

// The deck panel's partitions (tools/deck-panel/partitions.csv): nvs 0x9000+0x5000 (saved Wi-Fi, the update floor),
// otadata 0xe000+0x2000, app0 0x10000, app1 0x650000, spiffs 0xc90000, coredump 0xff0000.

/// Arduino-ESP32's boot_app0.bin (framework-arduinoespressif32/tools/partitions), what every `pio upload` writes at
/// 0xe000: otadata whose first entry is sequence 1 with its CRC (0x4743989A); the second is sequence 0, whose CRC is
/// FFFFFFFF. The higher sequence wins, so app0 boots. Bytes as read from the file.
private let bootApp0: [UInt8] = {
    var bytes = [UInt8](repeating: 0xFF, count: 0x2000)
    bytes.replaceSubrange(0..<4, with: [0x01, 0x00, 0x00, 0x00])
    bytes.replaceSubrange(0x1C..<0x20, with: [0x9A, 0x98, 0x43, 0x47])
    bytes.replaceSubrange(0x1000..<0x1004, with: [0x00, 0x00, 0x00, 0x00])
    return bytes
}()

private let app = panelApp(count: 5000, salt: 13)
private let wifi: [UInt8] = Array("saved Wi-Fi".utf8)

/// A panel that ran an update over Wi-Fi (#690): it boots app1, and has Wi-Fi saved and its other partitions in use.
private func panelOnApp1() async -> FakeROM {
    let rom = FakeROM()
    await rom.setFlash(wifi, at: 0x9000)
    await rom.setFlash([0x02, 0, 0, 0], at: 0xE000)  // otadata: sequence 2, app1
    await rom.setFlash([0xE9, 0xAA], at: 0x65_0000)
    await rom.setFlash([0x5A], at: 0xC9_0000)
    await rom.setFlash([0xC0], at: 0xFF_0000)
    return rom
}

private func flash(_ rom: FakeROM, wipeWiFi: Bool) async throws {
    let bootloader = Bootloader(line: rom)
    try await bootloader.connect()
    try await bootloader.checkChip()
    try await bootloader.flashApp(app, wipeWiFi: wipeWiFi) { _ in }
}

@Test func anUpdateWritesApp0AndBootApp0AndKeepsWiFiAndEverythingElse() async throws {
    let rom = await panelOnApp1()
    try await flash(rom, wipeWiFi: false)
    #expect(await rom.flashBytes(at: 0x10000, count: app.count) == app)
    #expect(await rom.flashBytes(at: 0xE000, count: 0x2000) == bootApp0)
    #expect(await rom.flashBytes(at: 0x9000, count: wifi.count) == wifi)
    #expect(await rom.flashBytes(at: 0x65_0000, count: 2) == [0xE9, 0xAA])
    #expect(await rom.flashBytes(at: 0xC9_0000, count: 1) == [0x5A])
    #expect(await rom.flashBytes(at: 0xFF_0000, count: 1) == [0xC0])
    #expect(await rom.begun.map(\.offset) == [0x10000, 0xE000])
}

@Test func onlyWhenTheOwnerAsksIsSavedWiFiWiped() async throws {
    let rom = await panelOnApp1()
    try await flash(rom, wipeWiFi: true)
    #expect(await rom.flashBytes(at: 0x9000, count: 0x5000).allSatisfy { $0 == 0xFF })
    #expect(await rom.begun.map(\.offset) == [0x10000, 0xE000, 0x9000])
    #expect(await rom.begun.last?.size == 0x5000)
    #expect(await rom.flashBytes(at: 0x65_0000, count: 2) == [0xE9, 0xAA])
}
