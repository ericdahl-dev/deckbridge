import Testing
import UnitCheck

struct FakeApps: RunningApps {
    var running: [String]
    func bundleIDs() async -> [String] { running }
}

@Suite("Unit check: DeckBridge running")
struct DeckBridgeRunningTests {
    /// DeckBridge's bundle id, project.yml (every build of it, the App Store one too).
    @Test("DeckBridge running: the check stops before update mode, with a plain reason")
    func deckBridgeRunning() async {
        let stop = await Preflight(apps: FakeApps(running: ["com.apple.finder", "dev.ericdahl.ControllerBridge"])).stop()
        #expect(stop == "DeckBridge is running. Quit it first: it talks to the LC6000.")
    }

    @Test("DeckBridge not running: nothing stops the check")
    func notRunning() async {
        #expect(await Preflight(apps: FakeApps(running: ["com.apple.finder", "dev.ericdahl.FirmwareUpdater"])).stop() == nil)
    }
}
