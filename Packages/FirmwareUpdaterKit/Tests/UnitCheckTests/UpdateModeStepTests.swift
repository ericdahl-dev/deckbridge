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
    @Test("The owner typed UPDATE: the kit's one message, sent once, to the WD port only")
    func sentOnUpdate() async throws {
        let midi = FakeMIDISend(ports: ["IAC Driver Bus 1"] + lc6000Ports)
        let outcome = await UpdateModeStep(midi: midi, apps: FakeApps(running: [])).enter(typed: "UPDATE")
        #expect(outcome == .sent)
        #expect(midi.sent.count == 1)
        #expect(midi.sent.first?.port == "LC6000 PRIME WD")
        #expect(midi.sent.first?.bytes == (try kitUpdateModeMessage()))
    }

    @Test("Anything but UPDATE typed: nothing is sent", arguments: ["", "update", "UPDATE ", "yes", "UPDATE\n"])
    func notSentOtherwise(typed: String) async {
        let midi = FakeMIDISend(ports: lc6000Ports)
        let outcome = await UpdateModeStep(midi: midi, apps: FakeApps(running: [])).enter(typed: typed)
        #expect(outcome == .refused("You didn't type UPDATE, so nothing was sent."))
        #expect(midi.sent.isEmpty)
    }

    @Test("No WD port, or two: nothing is sent, with a plain reason")
    func needsExactlyOneWDPort() async {
        let none = FakeMIDISend(ports: ["LC6000 PRIME Controller"])
        #expect(await UpdateModeStep(midi: none, apps: FakeApps(running: [])).enter(typed: "UPDATE")
            == .refused("The LC6000's display port isn't there. Is the LC6000 on, on a direct cable? Nothing was sent."))
        let two = FakeMIDISend(ports: lc6000Ports + ["LC6000 PRIME WD #2"])
        #expect(await UpdateModeStep(midi: two, apps: FakeApps(running: [])).enter(typed: "UPDATE")
            == .refused("There are two LC6000 display ports. Connect one LC6000 only. Nothing was sent."))
        #expect(none.sent.isEmpty && two.sent.isEmpty)
    }

    @Test("DeckBridge running: nothing is sent")
    func notWithDeckBridge() async {
        let midi = FakeMIDISend(ports: lc6000Ports)
        let outcome = await UpdateModeStep(midi: midi, apps: FakeApps(running: ["dev.ericdahl.ControllerBridge"])).enter(typed: "UPDATE")
        #expect(outcome == .refused("DeckBridge is running. Quit it first: it talks to the LC6000."))
        #expect(midi.sent.isEmpty)
    }
}
