#if DEBUG
import Testing
import UpdaterScreen

/// The screenshot preview (#761, Debug builds only): fixed states on fake ports, so the window can be shot with any
/// device on the Mac and none of them touched.
@MainActor @Suite("Updater: the screenshot preview's fixed states")
struct PreviewTests {
    @Test("Nothing plugged in: both sections say not found")
    func nothing() async {
        let model = Updater.preview(.nothing)
        await model.refresh()
        #expect(model.screen.firstLookLine == "first look: deck panel not found, LC6000 not found")
    }

    @Test("Panel and LC6000 found: the panel's build is read, an update is offered, the LC6000 warning is accepted")
    func found() async {
        let model = Updater.preview(.found)
        await model.refresh()
        #expect(model.screen.firstLookLine == "first look: deck panel found (build read), LC6000 found")
        #expect(model.screen.panelUpdate != nil)
        #expect(model.screen.lc6000.warning == nil)
    }

    @Test("During a panel update: it stays on its writing step, with Cancel off")
    func updating() async {
        let model = Updater.preview(.updating)
        await model.refresh()
        let update = Task { await model.updatePanel() }
        while model.canCancel || !model.updating { await Task.yield() }
        #expect(model.updating)
        #expect(!model.canCancel)
        #expect(model.screen.update == "Writing the new firmware: 42%")
        update.cancel()
    }
}
#endif
