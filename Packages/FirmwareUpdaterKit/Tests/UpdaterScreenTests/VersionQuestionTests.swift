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
        #expect(rig.serial.writes == [.init(port: Screen.port, baud: 921_600, text: "version\n")])
    }

    /// The version question on the panel's port at 921600: the only write the finder may ever make.
    static let question = FakeSerial.Write(port: Screen.port, baud: 921_600, text: "version\n")

    @Test("The only write is \"version\\n\", on the CH340K's port at 921600: another board's port and a panel at 115200 get nothing")
    func onlyTheQuestion() async {
        let rig = Rig()
        Screen.panel(rig, printing: [])
        rig.serial.oldLines[Screen.port] = ["deck panel: boot, build 1d0683f"]  // flashed before #667: can't answer
        rig.usb.plugged.append(USBDevice(vendor: 0x0403, product: 0x6001, name: "FT232R", serialPort: "/dev/cu.usbserial-A1"))
        #expect(await rig.finder.find().panel == .onSerial(build: PanelBuild(sha: "1d0683f")))
        #expect(rig.serial.writes == [Self.question])
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
}
