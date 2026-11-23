import PanelFlasher
import Testing
import UpdaterScreen

/// The brand review's words (#763): what the owner reads names Denon's part plainly.
@Suite("Updater: brand wording")
struct BrandWordingTests {
    @Test("The LC6000 warning says Denon doesn't make, support or endorse it")
    func denonLine() {
        #expect(UpdaterScreen.lc6000Warning.contains("It is not made, supported or endorsed by Denon."))
    }

    /// Every line that sends the owner to DeckBridge's switch quotes it the same way.
    @Test("Each cable line has the one quoted sentence", arguments: [
        UpdaterScreen.portBusy,
        UpdaterScreen.deckBridgeNoAnswer,
        PanelUpdate.Step.failed(.portBusy).text,
    ])
    func oneCableSentence(line: String) {
        #expect(line.contains("Turn off \"Send over the USB cable\" in DeckBridge"))
    }

    @Test("The window is titled with the app's whole name (#763)")
    func appName() {
        #expect(UpdaterScreen.appName == "DeckBridge Firmware Updater")
    }
}
