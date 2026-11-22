import DeviceFinder
import Testing
import UpdaterScreen

/// The log's first look (#734): one line naming what each section found, in status words only. No build, serial
/// number or port goes in it, so the launch smoke check in CI can match it exactly.
@Suite("Updater: the first look's log line")
struct FirstLookTests {
    @Test("With nothing plugged in, both sections say not found, warning accepted or not")
    func nothingFound() async {
        let rig = Rig()
        let line = "first look: deck panel not found, LC6000 not found"
        #expect(await rig.screen().firstLookLine == line)
        #expect(UpdaterScreen(found: Found(), lc6000WarningAccepted: true).firstLookLine == line)
    }

    @Test("A panel that told its build: found, and the build itself stays out of the line")
    func panelBuildLeftOut() async {
        let rig = Rig()
        UpdaterScreenTests.panel(rig, printing: ["deck panel: boot, build 1d0683f"])
        let line = await rig.screen().firstLookLine
        #expect(line == "first look: deck panel found (build read), LC6000 not found")
        #expect(!line.contains("1d0683f"))
        #expect(!line.contains("/dev/"))
    }

    @Test("Each other state has its own words")
    func otherStates() {
        func line(_ panel: PanelFound?, _ lc6000: LC6000Found?) -> String {
            var found = Found()
            found.panel = panel
            found.lc6000 = lc6000
            return UpdaterScreen(found: found, lc6000WarningAccepted: false).firstLookLine
        }
        #expect(line(.driverMissing, .onMIDI) == "first look: deck panel found (driver missing), LC6000 found")
        #expect(line(.portBusy, .updateMode) == "first look: deck panel found (port busy), LC6000 in update mode")
        #expect(line(.onSerial(build: nil), nil) == "first look: deck panel found (build not read), LC6000 not found")
    }

    @Test("A panel whose port may still come (#700): waiting, never driver missing")
    func panelWaiting() {
        let screen = UpdaterScreen(found: Found(panel: .driverMissing), lc6000WarningAccepted: false, panelWaiting: true)
        #expect(screen.firstLookLine == "first look: deck panel found (waiting for its port), LC6000 not found")
    }
}
