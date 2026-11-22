import Testing
import UnitCheck

/// Alt names as ST's ROM bootloader gives them (dfu-util -l), layouts from tools/lc6000-firmware/drawn_plan.py.
let displayAlt = "@Internal Flash  /0x08000000/04*016Kg,01*064Kg,07*128Kg"
let topPanelAlt = "@Internal Flash  /0x08000000/04*016Kg,01*064Kg,01*128Kg"
let optionAlt = "@Option Bytes  /0x1FFFC000/01*016 e"

@Suite("Unit check: which chip is in update mode")
struct WhichChipTests {
    @Test("One device with the 1 MB layout is the display chip; the 256 KB one is the top panel chip")
    func oneChip() {
        #expect(UpdateModeDevices.judge([DFUDevice(path: "1-1", altNames: [displayAlt, optionAlt])]) == .one(.display, path: "1-1"))
        #expect(UpdateModeDevices.judge([DFUDevice(path: "1-2", altNames: [topPanelAlt, optionAlt])]) == .one(.topPanel, path: "1-2"))
    }

    @Test("None, two, or a layout that is neither chip's: refused, with a plain reason",
          arguments: [
              ([], "No device in update mode."),
              ([DFUDevice(path: "1-1", altNames: [displayAlt]), DFUDevice(path: "1-2", altNames: [topPanelAlt])],
               "2 devices are in update mode. Exactly one is needed: power the LC6000 off and on, then put one chip in update mode."),
              ([DFUDevice(path: "1-1", altNames: ["@Internal Flash  /0x08000000/04*016Kg,01*064Kg,03*128Kg"])],
               "Its memory layout is neither LC6000 chip's, so it isn't one. Nothing was read."),
          ])
    func refused(devices: [DFUDevice], reason: String) {
        #expect(UpdateModeDevices.judge(devices) == .refused(reason))
    }
}
