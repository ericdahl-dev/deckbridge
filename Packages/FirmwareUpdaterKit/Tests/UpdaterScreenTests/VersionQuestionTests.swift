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
}
