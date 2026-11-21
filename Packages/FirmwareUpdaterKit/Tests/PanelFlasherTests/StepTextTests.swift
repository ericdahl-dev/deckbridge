import FirmwareModel
import Testing
@testable import PanelFlasher

// What the owner reads while the panel updates (#687), in plain words.

@Test(arguments: [
    (PanelUpdate.Step.connecting, "Connecting to the deck panel…"),
    (.writing(0.426), "Writing the new firmware: 42%"),
    (.restarting, "Restarting the deck panel…"),
    (.done(PanelBuild(sha: "1d0683f", version: FirmwareVersion("1.1.0"))), "Updated: the panel now runs 1.1.0 (build 1d0683f)"),
    (.done(PanelBuild(sha: "1d0683f")), "Updated: the panel now runs build 1d0683f"),
    (.done(nil), "Updated. The panel's build wasn't read: unplug it and plug it back in to see it"),
])
func eachStepReadsPlainly(step: PanelUpdate.Step, text: String) {
    #expect(step.text == text)
}

@Test(arguments: [
    (FlashError.portBusy, "DeckBridge is using the panel's cable. Turn off \"Send over the USB cable\" in DeckBridge, then try again."),
    (.wrongBoard("chip id 5"), "This board isn't a deck panel (chip id 5). Nothing was written."),
    (.notADeckPanel, "This board doesn't have the deck panel's layout. Nothing was written."),
    (.noBootloader, "The panel didn't answer. Unplug it, plug it back in, and try again."),
    (.writeFailed(address: 0x10400), "Writing failed at 0x10400. The panel may not start: try again before unplugging it."),
    (.verifyFailed(address: 0x10000), "The written firmware didn't check out. The panel may not start: try again before unplugging it."),
    (.cancelled, "Cancelled. The panel was restarted."),
    (.lineLost, "The cable was lost. Plug the panel back in and try again."),
])
func eachFailureSaysWhatHappenedAndWhatToDo(error: FlashError, text: String) {
    #expect(PanelUpdate.Step.failed(error).text == text)
}
