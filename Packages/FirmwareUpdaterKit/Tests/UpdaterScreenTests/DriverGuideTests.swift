import DeviceFinder
import Foundation
import Testing
import UpdaterScreen

/// The driver guide (#688): a panel whose chip has no driver gets the steps to install WCH's CH34x driver.
@Suite("Updater: the deck panel's driver guide")
struct DriverGuideTests {
    static func panelWithoutDriver(_ rig: Rig) {
        rig.usb.plugged = [USBDevice(vendor: 0x1A86, product: 0x7522, name: "USB Serial")]
    }

    @Test("A panel with no driver: the section carries the four steps in order, and WCH's download page")
    func guideSteps() async throws {
        let rig = Rig()
        Self.panelWithoutDriver(rig)
        let guide = try #require(await rig.screen().panel.guide)
        #expect(guide.steps == [
            "Download the CH34x driver for macOS from WCH, the chip's maker.",
            "Open the download, drag CH34xVCPDriver to Applications, open it, and click Install.",
            "If macOS asks, allow the driver in System Settings > General > Login Items & Extensions > Driver Extensions.",
            "Unplug the panel and plug it back in. This app looks again by itself.",
        ])
        #expect(guide.link == URL(string: "https://www.wch-ic.com/downloads/CH34XSER_MAC_ZIP.html"))
    }

    @Test("The guide links only to WCH's own site, over https")
    func guideLinksOnlyToWCH() async throws {
        let rig = Rig()
        Self.panelWithoutDriver(rig)
        let guide = try #require(await rig.screen().panel.guide)
        #expect(guide.link.scheme == "https")
        #expect(guide.link.host == "www.wch-ic.com")
        for step in guide.steps {
            #expect(!step.contains("http"), "a step carries a link: \(step)")
        }
    }

    @Test("No guide when nothing is plugged in, or the driver already made the panel's serial port")
    func noGuideWhenNotNeeded() async {
        let nothing = Rig()
        #expect(await nothing.screen().panel.guide == nil)

        let withDriver = Rig()
        withDriver.usb.plugged = [USBDevice(vendor: 0x1A86, product: 0x7522, name: "USB Serial",
                                            serialPort: "/dev/cu.wchusbserial210")]
        withDriver.serial.lines["/dev/cu.wchusbserial210"] = ["deck panel: boot, build 1d0683f"]
        let screen = await withDriver.screen()
        #expect(screen.panel.detail == "Build 1d0683f")
        #expect(screen.panel.guide == nil)
        #expect(screen.lc6000.guide == nil)
    }
}
