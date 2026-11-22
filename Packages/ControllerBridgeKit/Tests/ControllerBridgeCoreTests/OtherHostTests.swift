@testable import ControllerBridgeCore
import Testing

/// Another DJ app holding the LC6000 as host (#333). The detector comes after the spike; this is the plumbing, driven
/// by its test-only signal.
@Suite("Another host")
struct OtherHostTests {
    @Test("The signal reaches the status and Diagnostics' log, once each way")
    func status() throws {
        let rig = try Rig()
        rig.coordinator.start()
        #expect(rig.coordinator.status.otherHost == false)
        rig.coordinator.otherHostChanged(true)
        rig.coordinator.otherHostChanged(true)
        #expect(rig.coordinator.status.otherHost == true)
        #expect(rig.log.lines.filter { $0 == "Another DJ app is using the LC6000 as its host" }.count == 1)
        rig.coordinator.otherHostChanged(false)
        #expect(rig.coordinator.status.otherHost == false)
        #expect(rig.log.lines.last == "The other DJ app let go of the LC6000")
    }
}
