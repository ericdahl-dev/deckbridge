import Testing
import UnitCheck

/// The read-only requests, from dfu-util's DfuSe upload (`dfu-util -s <address>:<length> -U`, as
/// tools/lc6000-firmware/flash-day.sh runs it): status, clear status, state, abort, upload, and the one download that
/// sets the address pointer (DfuSe command 0x21 with a 4-byte address). Anything else could change the chip.
func isReadOnly(_ r: DFURequest) -> Bool {
    switch (r.requestType, r.request) {
    case (0xA1, 3): return r.data.isEmpty && r.length == 6 // GETSTATUS
    case (0xA1, 5): return r.data.isEmpty && r.length == 1 // GETSTATE
    case (0x21, 4), (0x21, 6): return r.data.isEmpty && r.length == 0 && r.value == 0 // CLRSTATUS, ABORT
    case (0xA1, 2): return r.data.isEmpty && r.value >= 2 // UPLOAD of a block
    case (0x21, 1): return r.value == 0 && r.data.count == 5 && r.data[0] == 0x21 // DNLOAD block 0: set address only
    default: return false
    }
}

@Suite("Unit check: reading a chip in update mode")
struct DFUReadTests {
    @Test("A read sends only the read-only requests: no erase, no download of data, nothing else")
    func onlyReadOnlyRequests() async throws {
        let chip = FakeChip(size: 0x8_0000)
        _ = try await DFUReader(transport: chip).read(address: 0x0800_8000, length: 0x1_0000)
        #expect(!chip.log.isEmpty)
        for request in chip.log {
            #expect(isReadOnly(request), "not a read-only request: \(request)")
        }
    }

    @Test("The whitelist itself refuses an erase, a data download, a set-address in another block, and a detach")
    func whitelistRefusesWrites() {
        let erase = DFURequest(requestType: 0x21, request: 1, value: 0, index: 0, data: [0x41, 0x00, 0x80, 0x00, 0x08])
        let massErase = DFURequest(requestType: 0x21, request: 1, value: 0, index: 0, data: [0x41])
        let write = DFURequest(requestType: 0x21, request: 1, value: 2, index: 0, data: [0x00, 0x01, 0x02, 0x03])
        let addressInBlock2 = DFURequest(requestType: 0x21, request: 1, value: 2, index: 0, data: [0x21, 0x00, 0x80, 0x00, 0x08])
        let readUnprotect = DFURequest(requestType: 0x21, request: 1, value: 0, index: 0, data: [0x92])
        let detach = DFURequest(requestType: 0x21, request: 0, value: 1000, index: 0)
        let setAddress = DFURequest(requestType: 0x21, request: 1, value: 0, index: 0, data: [0x21, 0x00, 0x80, 0x00, 0x08])
        for request in [erase, massErase, write, addressInBlock2, readUnprotect, detach] {
            #expect(!isReadOnly(request), "let through: \(request)")
        }
        #expect(isReadOnly(setAddress))
    }
}
