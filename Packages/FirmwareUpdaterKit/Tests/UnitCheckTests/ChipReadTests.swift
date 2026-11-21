import Testing
import UnitCheck

@Suite("Unit check: what is read from each chip")
struct ChipReadTests {
    @Test("Display chip: the settings sector and the app, at the kit's addresses (flash-day.sh)")
    func displayAreas() async throws {
        let chip = FakeChip(size: 0x10_0000)
        let read = try await ChipRead.read(.display, from: DFUReader(transport: chip))
        #expect(read.settings == Array(chip.flash[0x4000..<0x8000]))   // 0x08004000, 0x4000
        #expect(read.app == Array(chip.flash[0x8000..<0x8_0000]))      // 0x08008000, 0x78000
        #expect(chip.log.allSatisfy(isReadOnly))
    }

    @Test("Top panel chip: sector 1 and the app area up to the end of its 256 KB (drawn_plan.py's layout)")
    func topPanelAreas() async throws {
        let chip = FakeChip(size: 0x4_0000)
        let read = try await ChipRead.read(.topPanel, from: DFUReader(transport: chip))
        #expect(read.settings == Array(chip.flash[0x4000..<0x8000]))   // 0x08004000, 0x4000
        #expect(read.app == Array(chip.flash[0x8000..<0x4_0000]))      // 0x08008000, 0x38000
        #expect(chip.log.allSatisfy(isReadOnly))
    }
}

@Suite("Unit check: a unit that leaves update mode mid-read")
struct LeavesMidReadTests {
    @Test("The read stops at once with a plain reason, and asks the unit nothing more: no retry")
    func leavesMidRead() async {
        let chip = FakeChip(size: 0x10_0000)
        chip.leavesAfterUploads = 3
        await #expect(throws: DFUError.left) {
            try await ChipRead.read(.display, from: DFUReader(transport: chip))
        }
        let uploads = chip.log.filter { $0.requestType == 0xA1 && $0.request == 2 }
        #expect(uploads.count == 4) // three answered, the fourth found it gone
        #expect(chip.log.last.map { $0.requestType == 0xA1 && $0.request == 2 } == true)
        #expect(DFUError.left.reason == "The unit left update mode during the read. Nothing was saved.")
    }
}
