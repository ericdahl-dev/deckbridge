import DeviceFinder
import FirmwareModel
import Testing
import UpdaterScreen

/// The app shell (#685): two sections, deck panel and LC6000, saying what is connected. Driven by fake ports.
@Suite("Updater: what is connected")
struct UpdaterScreenTests {
    @Test("With nothing plugged in, both sections say nothing is connected")
    func nothingConnected() async {
        let screen = await Rig().screen()
        #expect(screen.panel.status == "Nothing connected")
        #expect(screen.lc6000.status == "Nothing connected")
    }

    /// The CrowPanel's USB serial chip, a CH340K (tools/deck-panel/README.md).
    static let ch340k = (vendor: UInt16(0x1A86), product: UInt16(0x7522))

    @Test("A panel on USB with no serial port: found, and its driver is missing")
    func panelWithoutDriver() async {
        let rig = Rig()
        rig.usb.plugged = [USBDevice(vendor: Self.ch340k.vendor, product: Self.ch340k.product, name: "USB Serial")]
        let screen = await rig.screen()
        #expect(screen.panel.status == "Deck panel found")
        #expect(screen.panel.detail == "The USB driver for its chip is missing")
        #expect(screen.lc6000.status == "Nothing connected")
    }

    static let port = "/dev/cu.wchusbserial210"

    static func panel(_ rig: Rig, printing lines: [String]) {
        rig.usb.plugged = [USBDevice(vendor: ch340k.vendor, product: ch340k.product, name: "USB Serial", serialPort: port)]
        rig.serial.lines[port] = lines
    }

    @Test("A panel that boots while the app listens: found, with the build from its boot line")
    func panelBuild() async {
        let rig = Rig()
        Self.panel(rig, printing: ["ESP-ROM:esp32s3-20210327", "deck panel: boot, build 1d0683f", "deck panel: waiting"])
        let screen = await rig.screen()
        #expect(screen.panel.status == "Deck panel found")
        #expect(screen.panel.detail == "Build 1d0683f")
    }

    @Test("A panel that didn't boot while the app listened, or gave no real build: build not read, and no unplug advice (#699 owner run: a replug is not seen)",
          arguments: [
              [],
              ["deck panel: waiting"],
              ["deck panel: boot, build unknown"],
              ["deck panel: boot, build 1d06"],
              ["deck panel: boot, build 1D0683Z"],
          ])
    func panelBuildNotRead(lines: [String]) async {
        let rig = Rig()
        Self.panel(rig, printing: lines)
        let screen = await rig.screen()
        #expect(screen.panel.status == "Deck panel found")
        #expect(screen.panel.detail == "Build not read")
    }

    @Test("A development build (uncommitted changes, tools/deck-panel/git_sha.py) shows as one, SHA as printed")
    func panelDevelopmentBuild() async {
        let rig = Rig()
        Self.panel(rig, printing: ["deck panel: boot, build 1d0683f-dirty"])
        let found = await rig.finder.find()
        #expect(found.panel == .onSerial(build: PanelBuild(sha: "1d0683f-dirty")))
        let screen = UpdaterScreen(found: found, lc6000WarningAccepted: true)
        #expect(screen.panel.detail == "Build 1d0683f-dirty (a development build)")
    }

    @Test("#695's boot line: the build and its version, both read",
          arguments: [
              ("deck panel: boot, build 1d0683f", PanelBuild(sha: "1d0683f")),
              ("deck panel: boot, build 1d0683f, version 1.2.0", PanelBuild(sha: "1d0683f", version: FirmwareVersion("1.2.0"))),
              ("deck panel: boot, build 1d0683f, version 1.10", PanelBuild(sha: "1d0683f", version: FirmwareVersion("1.10"))),
          ])
    func panelVersion(line: String, build: PanelBuild) async {
        let rig = Rig()
        Self.panel(rig, printing: [line])
        #expect(await rig.finder.find().panel == .onSerial(build: build))
    }

    @Test("A local or development build gives no version, so the SHA decides; the SHA reads as printed",
          arguments: [
              ("deck panel: boot, build 1d0683f, version 1.2.0 local", "1d0683f"),
              ("deck panel: boot, build 1d0683f-dirty, version 1.2.0 local", "1d0683f-dirty"),
              ("deck panel: boot, build 1d0683f-dirty, version 1.2.0", "1d0683f-dirty"),
          ])
    func panelLocalBuildHasNoVersion(line: String, sha: String) async {
        let rig = Rig()
        Self.panel(rig, printing: [line])
        #expect(await rig.finder.find().panel == .onSerial(build: PanelBuild(sha: sha)))
    }

    @Test("A boot line whose version tail isn't dotted digits: build not read",
          arguments: [
              "deck panel: boot, build 1d0683f, version ",
              "deck panel: boot, build 1d0683f, version 1.x",
              "deck panel: boot, build 1d0683f, version +1.2",
              "deck panel: boot, build 1d0683f, version 1..2",
              "deck panel: boot, build 1d0683f, version 1.2.0 beta",
              "deck panel: boot, build 1d0683f, 1.2.0",
          ])
    func panelBadVersion(line: String) async {
        let rig = Rig()
        Self.panel(rig, printing: [line])
        #expect(await rig.finder.find().panel == .onSerial(build: nil))
    }

    @Test("A panel since #667 talks at 921600: read there, and 115200 isn't tried")
    func panelAt921600() async {
        let rig = Rig()
        Self.panel(rig, printing: ["\u{FFFD}\u{FFFD}x", "deck panel: boot, build 1d0683f, version 1.2.0"])
        #expect(await rig.finder.find().panel == .onSerial(build: PanelBuild(sha: "1d0683f", version: FirmwareVersion("1.2.0"))))
        #expect(rig.serial.bauds == [921_600])
    }

    @Test("A panel flashed before #667 talks at 115200: tried after 921600, and read there")
    func panelAt115200() async {
        let rig = Rig()
        Self.panel(rig, printing: ["\u{FFFD}x\u{FFFD}"])
        rig.serial.oldLines[Self.port] = ["deck panel: boot, build 1d0683f"]
        #expect(await rig.finder.find().panel == .onSerial(build: PanelBuild(sha: "1d0683f")))
        #expect(rig.serial.bauds == [921_600, 115_200])
    }

    @Test("Nothing read at either speed: build not read, both tried once, on the panel's port only")
    func panelAtNeitherSpeed() async {
        let rig = Rig()
        Self.panel(rig, printing: [])
        let screen = await rig.screen()
        #expect(screen.panel.detail == "Build not read")
        #expect(rig.serial.bauds == [921_600, 115_200])
        #expect(rig.serial.opened == [Self.port, Self.port])
    }

    @Test("DeckBridge holds the panel's port: the screen says to turn off Send over the USB cable, and nothing else is tried")
    func portBusy() async {
        let rig = Rig()
        Self.panel(rig, printing: ["deck panel: boot, build 1d0683f"])
        rig.serial.busy = [Self.port]
        let screen = await rig.screen()
        #expect(screen.panel.status == "Deck panel found")
        #expect(screen.panel.detail == "DeckBridge is using the panel's USB cable. Turn off \"Send over the USB cable\" in DeckBridge, then look again.")
        #expect(UpdaterScreen.portBusy == screen.panel.detail)
        #expect(rig.serial.bauds == [921_600])
        #expect(rig.log.text.contains("deck panel: on USB 1A86:7522, serial port busy (another app has it)"))
    }

    @Test("An LC6000 on MIDI (DeckBridge's port names): found, firmware not checked yet")
    func lc6000OnMIDI() async {
        let rig = Rig()
        rig.midi.ports = ["IAC Driver Bus 1", "LC6000 PRIME Controller", "LC6000 PRIME WD"]
        let screen = await rig.screen()
        #expect(screen.lc6000.status == "LC6000 found")
        #expect(screen.lc6000.detail == "Firmware not checked yet")
        #expect(screen.panel.status == "Nothing connected")
    }

    /// The look only sees ST's bootloader on USB, not which chip: naming it would need a new request at every look
    /// (#762, cos: option 1). The backup names it.
    @Test("ST's ROM bootloader on USB (0483:DF11): an LC6000 chip in update mode")
    func deviceInUpdateMode() async {
        let rig = Rig()
        rig.usb.plugged = [USBDevice(vendor: 0x0483, product: 0xDF11, name: "STM32  BOOTLOADER")]
        let screen = await rig.screen()
        #expect(screen.lc6000.status == "An LC6000 chip in update mode")
        #expect(screen.lc6000.detail == nil)
    }

    /// #762: the LC6000's steps show only when an LC6000 is there, and quitting DeckBridge is the first of them.
    @Test("LC6000 steps: quit DeckBridge first, then update mode, then the backup")
    func lc6000StepOrder() {
        #expect(UpdaterScreen.lc6000Steps.first == "Quit DeckBridge first. It talks to the LC6000.")
        #expect(UpdaterScreen.lc6000Steps.count == 4)
        #expect(UpdaterScreen.lc6000Steps[1].hasPrefix("Put one chip in update mode."))
        #expect(UpdaterScreen.lc6000Steps.last?.hasPrefix("Then pick a folder.") == true)
        #expect(!UpdaterScreen.lc6000Steps.joined().contains("quit DeckBridge"))
    }

    @Test("No LC6000: no steps, and the section says to plug it in; found on MIDI or in update mode: the steps")
    func lc6000StepsOnlyWhenFound() async {
        let rig = Rig()
        let none = await rig.screen()
        #expect(!none.showsLC6000Steps)
        #expect(none.lc6000.detail == "Plug in the LC6000 and switch it on.")
        rig.midi.ports = ["LC6000 PRIME Controller"]
        #expect(await rig.screen().showsLC6000Steps)
        rig.midi.ports = []
        rig.usb.plugged = [USBDevice(vendor: 0x0483, product: 0xDF11, name: "STM32  BOOTLOADER")]
        #expect(await rig.screen().showsLC6000Steps)
        #expect(!(await rig.screen(lc6000WarningAccepted: false).showsLC6000Steps))
    }

    @Test("Finding opens no serial port but the panel's own: another device's port is never touched, and opening resets some boards")
    func opensOnlyThePanelsPort() async {
        let rig = Rig()
        rig.usb.plugged = [
            USBDevice(vendor: 0x0403, product: 0x6001, name: "FT232R USB UART", serialPort: "/dev/cu.usbserial-A1"),
            USBDevice(vendor: 0x10C4, product: 0xEA60, name: "CP2102", serialPort: "/dev/cu.SLAB_USBtoUART"),
            USBDevice(vendor: 0x0483, product: 0xDF11, name: "STM32  BOOTLOADER"),
        ]
        rig.midi.ports = ["LC6000 PRIME Controller"]
        _ = await rig.finder.find()
        #expect(rig.serial.opened == [])

        Self.panel(rig, printing: [])
        rig.usb.plugged.append(USBDevice(vendor: 0x0403, product: 0x6001, name: "FT232R USB UART", serialPort: "/dev/cu.usbserial-A1"))
        _ = await rig.finder.find()
        #expect(rig.serial.opened == [Self.port, Self.port]) // 921600, then 115200
    }

    @Test("The LC6000 section shows only its warning until the owner accepts it; the panel section isn't locked")
    func lc6000BehindWarning() async throws {
        let rig = Rig()
        rig.midi.ports = ["LC6000 PRIME Controller"]
        Self.panel(rig, printing: ["deck panel: boot, build 1d0683f"])
        let locked = await rig.screen(lc6000WarningAccepted: false)
        let warning = try #require(locked.lc6000.warning)
        #expect(warning.contains("debug probe"))
        #expect(locked.lc6000.status == "Read the warning first")
        #expect(locked.lc6000.detail == nil)
        #expect(locked.panel.detail == "Build 1d0683f")
        #expect(locked.panel.warning == nil)

        let open = await rig.screen(lc6000WarningAccepted: true)
        #expect(open.lc6000.warning == nil)
        #expect(open.lc6000.status == "LC6000 found")
    }

    @Test("The log says what was found, and leaves out serial numbers, MAC addresses and Wi-Fi details")
    func logLeavesOutPrivateDetails() async {
        let rig = Rig()
        // A driver that names the port after the chip's serial number, as FTDI's and Apple's do.
        let port = "/dev/cu.usbserial-AB12CD34"
        rig.usb.plugged = [USBDevice(vendor: Self.ch340k.vendor, product: Self.ch340k.product, name: "USB Serial", serialPort: port)]
        rig.serial.lines[port] = [
            "deck panel: boot, build 1d0683f",
            "wifi: joined \"HomeNet-5G\" password hunter22",
            "wifi: mac 24:6F:28:AA:BB:CC, address 192.168.1.42",
        ]
        rig.midi.ports = ["LC6000 PRIME Controller"]
        _ = await rig.finder.find()
        let log = rig.log.text
        #expect(log.contains("deck panel"))
        #expect(log.contains("1A86:7522"))
        #expect(log.contains("build 1d0683f"))
        #expect(log.contains("LC6000"))
        for secret in ["AB12CD34", "HomeNet", "hunter22", "24:6F:28", "AA:BB:CC", "192.168"] {
            #expect(!log.contains(secret), "log has \(secret)")
        }
    }
}

/// For the panel flasher (#687): the panel's serial port, picked by the same chip ids the finder uses.
@Suite("Device finder: the panel's port")
struct PanelPortTests {
    @Test("The CH340K's port, not another board's; nil when the panel has no port or isn't there")
    func panelPort() {
        let other = USBDevice(vendor: 0x0403, product: 0x6001, name: "FT232R USB UART", serialPort: "/dev/cu.usbserial-A1")
        let panel = USBDevice(vendor: 0x1A86, product: 0x7522, name: "USB Serial", serialPort: "/dev/cu.wchusbserial210")
        let panelNoPort = USBDevice(vendor: 0x1A86, product: 0x7522, name: "USB Serial")
        #expect(DeviceFinder.panelPort(in: [other, panel]) == "/dev/cu.wchusbserial210")
        #expect(DeviceFinder.panelPort(in: [other, panelNoPort]) == nil)
        #expect(DeviceFinder.panelPort(in: [other]) == nil)
    }
}
