import Testing
import UpdaterScreen

/// The brand review's words (#763): what the owner reads names Denon's part plainly.
@Suite("Updater: brand wording")
struct BrandWordingTests {
    @Test("The LC6000 warning says Denon doesn't make, support or endorse it")
    func denonLine() {
        #expect(UpdaterScreen.lc6000Warning.contains("It is not made, supported or endorsed by Denon."))
    }
}
