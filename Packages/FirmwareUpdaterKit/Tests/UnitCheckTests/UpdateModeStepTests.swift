import Foundation
import Testing
import UnitCheck

/// The kit's message, read from tools/lc6000-firmware/enter-update-mode.swift, so this test never retypes it.
func kitUpdateModeMessage() throws -> [UInt8] {
    let kit = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../tools/lc6000-firmware/enter-update-mode.swift").standardized
    let source = try String(contentsOf: kit, encoding: .utf8)
    let list = try #require(source.firstMatch(of: /let message: \[UInt8\] = \[([^\]]*)\]/)).1
    return try list.split(separator: ",").map { try #require(UInt8($0.trimmingCharacters(in: .whitespaces).dropFirst(2), radix: 16)) }
}

final class FakeMIDISend: MIDISend, @unchecked Sendable {
    let lock = NSLock()
    var ports: [String]
    private(set) var sent: [(port: String, bytes: [UInt8])] = []
    init(ports: [String]) { self.ports = ports }
    func destinations() async -> [String] { ports }
    func send(_ bytes: [UInt8], to port: String) async -> Bool {
        lock.withLock { sent.append((port, bytes)) }
        return true
    }
}

let lc6000Ports = ["LC6000 PRIME Controller", "LC6000 PRIME WD"]

@Suite("Unit check: the display chip's update-mode step")
struct UpdateModeStepTests {
    static let confirmed = UpdateModeStep.Confirmed(clicked: UpdateModeStep.confirmButton)!

    @Test("The owner confirmed: the kit's one message, sent once, to the WD port only")
    func sentOnUpdate() async throws {
        let midi = FakeMIDISend(ports: ["IAC Driver Bus 1"] + lc6000Ports)
        let outcome = await UpdateModeStep(midi: midi, apps: FakeApps(running: [])).enter(confirmed: Self.confirmed)
        #expect(outcome == .sent)
        #expect(midi.sent.count == 1)
        #expect(midi.sent.first?.port == "LC6000 PRIME WD")
        #expect(midi.sent.first?.bytes == (try kitUpdateModeMessage()))
    }

    @Test("Only the confirm's own button confirms: Cancel or any other button gives no go-ahead, so nothing is sent")
    func onlyTheConfirmButton() {
        #expect(UpdateModeStep.Confirmed(clicked: UpdateModeStep.confirmButton) != nil)
        for other in ["Cancel", "", "OK", "Write to the display chip"] {
            #expect(UpdateModeStep.Confirmed(clicked: other) == nil)
        }
    }

    /// The owner's decision (#762, 2026-11-22): no typed word here any more (it guards the write); a click, then a confirm
    /// that says what it does.
    @Test("The confirm says it restarts the chip into update mode, writes nothing, and a power cycle ends it")
    func confirmText() {
        #expect(UpdateModeStep.confirmTitle == "Restart the display chip in update mode?")
        #expect(UpdateModeStep.confirmBody == "This restarts the display chip into update mode. Nothing is written. A power cycle ends it.")
        #expect(UpdateModeStep.confirmButton == "Restart in update mode")
    }

    @Test("No WD port, or two: nothing is sent, with a plain reason")
    func needsExactlyOneWDPort() async {
        let none = FakeMIDISend(ports: ["LC6000 PRIME Controller"])
        #expect(await UpdateModeStep(midi: none, apps: FakeApps(running: [])).enter(confirmed: Self.confirmed)
            == .refused("The LC6000's display port isn't there. Is the LC6000 on, on a direct cable? Nothing was sent."))
        let two = FakeMIDISend(ports: lc6000Ports + ["LC6000 PRIME WD #2"])
        #expect(await UpdateModeStep(midi: two, apps: FakeApps(running: [])).enter(confirmed: Self.confirmed)
            == .refused("There are two LC6000 display ports. Connect one LC6000 only. Nothing was sent."))
        #expect(none.sent.isEmpty && two.sent.isEmpty)
    }

    @Test("DeckBridge running: nothing is sent")
    func notWithDeckBridge() async {
        let midi = FakeMIDISend(ports: lc6000Ports)
        let outcome = await UpdateModeStep(midi: midi, apps: FakeApps(running: ["dev.ericdahl.ControllerBridge"])).enter(confirmed: Self.confirmed)
        #expect(outcome == .refused("DeckBridge is running. Quit it first: it talks to the LC6000."))
        #expect(midi.sent.isEmpty)
    }
}

@Suite("Unit check: the update-mode message on the wire")
struct SysEx7Tests {
    /// The kit's own selftest vectors (tools/lc6000-firmware/enter-update-mode.swift, `selftest`).
    @Test("UMP SysEx7 packets as the kit packs them: the update-mode message, and a short SysEx")
    func kitVectors() throws {
        #expect(SysEx7.packets(try kitUpdateModeMessage()) == [[0x3016_0002, 0x0B01_1072], [0x3032_0000, 0x0000_0000]])
        #expect(SysEx7.packets([0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]) == [[0x3004_7E00, 0x0601_0000]])
    }

    /// The owner saw a power cycle end the display chip's update mode (2026-11-22): the screen says so, with no fear.
    @Test("After the step: back it up now, and a power cycle ends update mode")
    func sentText() {
        #expect(UpdateModeStep.sentText.contains("A power cycle ends update mode"))
        #expect(!UpdateModeStep.sentText.contains("isn't known"))
        #expect(!UpdateModeStep.sentText.contains("way back"))
    }
}
