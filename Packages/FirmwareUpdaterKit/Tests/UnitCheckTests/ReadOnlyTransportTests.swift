import Testing
import UnitCheck

@Suite("Unit check: the guard in front of the real USB")
struct ReadOnlyTransportTests {
    @Test("An erase, a data download, a detach or a read-unprotect never reaches the device")
    func refusesWrites() async {
        let chip = FakeChip(size: 0x10_0000)
        let guarded = ReadOnlyTransport(chip)
        let writes = [
            DFURequest(requestType: 0x21, request: 1, value: 0, index: 0, data: [0x41, 0x00, 0x80, 0x00, 0x08]),
            DFURequest(requestType: 0x21, request: 1, value: 0, index: 0, data: [0x41]),
            DFURequest(requestType: 0x21, request: 1, value: 2, index: 0, data: [0x00, 0x01, 0x02, 0x03]),
            DFURequest(requestType: 0x21, request: 1, value: 0, index: 0, data: [0x92]),
            DFURequest(requestType: 0x21, request: 0, value: 1000, index: 0),
        ]
        for request in writes {
            await #expect(throws: ReadOnlyTransport.Refused.self) { try await guarded.control(request) }
        }
        #expect(chip.log.isEmpty)
    }

    @Test("A whole read passes through the guard unchanged")
    func readPasses() async throws {
        let chip = FakeChip(size: 0x10_0000)
        let read = try await ChipRead.read(.display, from: DFUReader(transport: ReadOnlyTransport(chip)))
        #expect(read.app == Array(chip.flash[0x8000..<0x8_0000]))
    }
}
