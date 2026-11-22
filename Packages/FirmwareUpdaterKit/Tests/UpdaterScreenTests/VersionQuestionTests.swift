import DeviceFinder
import FirmwareModel
import Testing
import UpdaterScreen

/// The updater asks a running deck panel for its build (#715): the text line "version" to the panel's own console
/// (#695, #702), and its answer "deck panel: build <sha>, version <v>[ local]". Driven by fake ports.
@Suite("Updater: asking a running panel its version")
struct VersionQuestionTests {
    typealias Screen = UpdaterScreenTests

    /// A running panel with #702's firmware: it prints nothing until asked, then answers.
    static func runningPanel(_ rig: Rig, answering answer: String) {
        Screen.panel(rig, printing: [])
        rig.serial.answers[Screen.port] = [answer]
    }

    @Test("A running panel is asked \"version\" and its answer gives the build and version, with no replug")
    func runningPanelAnswers() async {
        let rig = Rig()
        Self.runningPanel(rig, answering: "deck panel: build 1d0683f, version 1.2.0")
        #expect(await rig.finder.find().panel == .onSerial(build: PanelBuild(sha: "1d0683f", version: FirmwareVersion("1.2.0"))))
        #expect(rig.serial.writes == [.init(port: Screen.port, baud: 921_600, text: "\nversion\n")])
    }

    /// The version question on the panel's port at 921600: the only write the finder may ever make.
    static let question = FakeSerial.Write(port: Screen.port, baud: 921_600, text: "\nversion\n")

    @Test("Today's firmware talks at 115200 (921600 comes with #711): asked at 921600, no answer, then asked at 115200")
    func answersAt115200() async {
        let rig = Rig()
        Screen.panel(rig, printing: [])
        rig.serial.oldAnswers[Screen.port] = ["deck panel: build d7f0f50a, version 1.0.0"]
        #expect(await rig.finder.find().panel == .onSerial(build: PanelBuild(sha: "d7f0f50a", version: FirmwareVersion("1.0.0"))))
    }

    @Test("The only writes are the version question, one per speed, on the CH340K's port: another board's port gets nothing")
    func onlyTheQuestion() async {
        let rig = Rig()
        Screen.panel(rig, printing: [])
        rig.usb.plugged.append(USBDevice(vendor: 0x0403, product: 0x6001, name: "FT232R", serialPort: "/dev/cu.usbserial-A1"))
        #expect(await rig.finder.find().panel == .onSerial(build: nil))
        #expect(rig.serial.writes == [Self.question, FakeSerial.Write(port: Screen.port, baud: 115_200, text: "\nversion\n")])
    }

    @Test("An answer at 921600 ends it: 115200 is neither opened nor asked")
    func answerAt921600Stops() async {
        let rig = Rig()
        Self.runningPanel(rig, answering: "deck panel: build 1d0683f, version 1.2.0")
        _ = await rig.finder.find()
        #expect(rig.serial.writes == [Self.question])
        #expect(rig.serial.bauds == [921_600])
    }

    @Test("A panel that doesn't answer (before #702): found, with an honest \"Build not read\" and no advice")
    func noAnswer() async {
        let rig = Rig()
        Screen.panel(rig, printing: [])
        let screen = await rig.screen()
        #expect(screen.panel.status == "Deck panel found")
        #expect(screen.panel.detail == "Build not read")
    }

    @Test("The answer follows the boot line's rules: local or development gives no version, a bad tail no build",
          arguments: [
              ("deck panel: build 1d0683f, version 1.2.0 local", PanelBuild(sha: "1d0683f")),
              ("deck panel: build 1d0683f-dirty, version 1.2.0", PanelBuild(sha: "1d0683f-dirty")),
              ("deck panel: build 1d0683f", PanelBuild(sha: "1d0683f")),
          ] as [(String, PanelBuild)])
    func answerRules(answer: String, build: PanelBuild) async {
        let rig = Rig()
        Self.runningPanel(rig, answering: answer)
        #expect(await rig.finder.find().panel == .onSerial(build: build))
    }

    @Test("An answer whose build or version isn't well formed: build not read",
          arguments: ["deck panel: build unknown, version 1.2.0", "deck panel: build 1d0683f, version 1.x",
                      "deck panel: build 1D0683F, version 1.2.0", "deck panel: builds 1d0683f"])
    func badAnswer(answer: String) async {
        let rig = Rig()
        Self.runningPanel(rig, answering: answer)
        #expect(await rig.finder.find().panel == .onSerial(build: nil))
    }

    @Test("DeckBridge holds the port: nothing is written, and the screen says to turn off Send over the USB cable")
    func busyWritesNothing() async {
        let rig = Rig()
        Self.runningPanel(rig, answering: "deck panel: build 1d0683f, version 1.2.0")
        rig.serial.busy = [Screen.port]
        let screen = await rig.screen()
        #expect(rig.serial.writes.isEmpty)
        #expect(screen.panel.detail == UpdaterScreen.portBusy)
    }

    @Test("The log has the checked build and version in fixed words, never the panel's answer as printed")
    func logLine() async {
        let rig = Rig()
        Self.runningPanel(rig, answering: "deck panel: build 1d0683f, version 1.2.0")
        _ = await rig.finder.find()
        #expect(rig.log.lines == ["deck panel: on USB 1A86:7522, serial port present, build 1d0683f, version 1.2.0"])
    }

    @Test("The screen shows the version with the build; with no version, the build alone")
    func screenWithVersion() async {
        let rig = Rig()
        Self.runningPanel(rig, answering: "deck panel: build 1d0683f, version 1.2.0")
        #expect(await rig.screen().panel.detail == "Version 1.2.0, build 1d0683f")
        let local = Rig()
        Self.runningPanel(local, answering: "deck panel: build 1d0683f, version 1.2.0 local")
        #expect(await local.screen().panel.detail == "Build 1d0683f")
    }

    // Each speed that read no build says why in the log (#710's owner run: "build not read" and nothing else). Counts
    // only: never the panel's own text, which may carry Wi-Fi names or addresses.

    @Test("A silent panel: the log says nothing came back, at each speed")
    func logsNothingBack() async {
        let rig = Rig()
        Screen.panel(rig, printing: [])
        _ = await rig.finder.find()
        #expect(rig.log.lines.contains("deck panel: asked at 921600, nothing back"))
        #expect(rig.log.lines.contains("deck panel: asked at 115200, nothing back"))
    }

    @Test("Lines but no answer: the log gives the count, not the lines")
    func logsLineCount() async {
        let rig = Rig()
        Screen.panel(rig, printing: ["frame avg 12 ms, ssid HomeNet", "heap 120k"])
        _ = await rig.finder.find()
        #expect(rig.log.lines.contains("deck panel: asked at 921600, 2 lines, no build line"))
        #expect(!rig.log.text.contains("HomeNet"))
    }

    @Test("The answer torn into another line (#754's perf build): the log says so, and the build isn't read from it")
    func logsTornAnswer() async {
        let rig = Rig()
        Self.runningPanel(rig, answering: "frame avg 1deck panel: build bf7268c, version 1.2.0")
        #expect(await rig.finder.find().panel == .onSerial(build: nil))
        #expect(rig.log.lines.contains("deck panel: asked at 921600, 1 line, build line torn inside another line"))
        #expect(!rig.log.text.contains("frame avg"))
    }

    @Test("An answer that isn't well formed: the log says the build line was bad, not that there was none")
    func logsBadAnswer() async {
        let rig = Rig()
        Self.runningPanel(rig, answering: "deck panel: build 1d0683f, version 1.x")
        _ = await rig.finder.find()
        #expect(rig.log.lines.contains("deck panel: asked at 921600, 1 line, build line not well formed"))
    }
}
