// Writing an LC6000 chip in ST's update mode (#693): only after the owner confirms this very plan, only the plan's
// sectors, erased and written as dfu-util's DfuSe download does it (erase 0x41, set address 0x21, DNLOAD blocks from
// 2), then read back and compared. Tested on a fake chip; on a unit, the owner runs every write.
import UnitCheck

/// The owner's confirm of one plan: the confirm sheet's button makes it, for the plan it showed.
public struct Confirmation: Sendable {
    let plan: WritePlan
    public init(_ plan: WritePlan) { self.plan = plan }
}

public enum WriteOutcome: Sendable, Equatable {
    /// Written, and read back equal.
    case written
    /// Read back different from the first byte at this address: restore from the backup.
    case mismatch(at: UInt32)
    /// The chip stopped answering, or refused a step: it may not start; the recovery guide says what to do.
    case noAnswer
    /// The confirm wasn't for this plan: nothing was sent.
    case refused
}

public struct ChipWriter: Sendable {
    let transport: any DFUTransport
    let interface: UInt16
    let transferSize: Int

    public init(transport: any DFUTransport, interface: UInt16 = 0, transferSize: Int = 2048) {
        self.transport = transport
        self.interface = interface
        self.transferSize = transferSize
    }

    public func write(_ plan: WritePlan, confirmed: Confirmation) async -> WriteOutcome {
        guard confirmed.plan == plan else { return .refused }
        let guarded = PlanTransport(transport, plan: plan, transferSize: transferSize)
        do {
            for sector in plan.sectors {
                try await toIdle(guarded)
                try await command(0x41, sector.address, on: guarded)  // erase the sector
                try await command(0x21, sector.address, on: guarded)  // the pointer to its start
                var block: UInt16 = 2
                for start in stride(from: 0, to: sector.bytes.count, by: transferSize) {
                    let chunk = Array(sector.bytes[start..<min(start + transferSize, sector.bytes.count)])
                    _ = try await guarded.control(DFURequest(requestType: 0x21, request: 1, value: block, index: interface, data: chunk))
                    try await waitWhileBusy(guarded)
                    block += 1
                }
                _ = try await guarded.control(DFURequest(requestType: 0x21, request: 6, value: 0, index: interface))
            }
        } catch {
            return .noAnswer
        }
        let reader = DFUReader(transport: guarded, interface: interface, transferSize: transferSize)
        for sector in plan.sectors {
            guard let back = try? await reader.read(address: sector.address, length: sector.bytes.count) else { return .noAnswer }
            if let i = sector.bytes.indices.first(where: { back[$0] != sector.bytes[$0] }) {
                return .mismatch(at: sector.address + UInt32(i))
            }
        }
        return .written
    }

    /// A DfuSe command in block 0: the command byte and a little-endian address, then the status poll that runs it.
    private func command(_ code: UInt8, _ a: UInt32, on t: PlanTransport) async throws {
        _ = try await t.control(DFURequest(requestType: 0x21, request: 1, value: 0, index: interface,
                                           data: [code, UInt8(a & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a >> 16 & 0xFF), UInt8(a >> 24)]))
        try await waitWhileBusy(t)
    }

    private struct Failed: Error {}

    /// As dfu-util: poll, waiting the chip's poll timeout, while it's busy. An error status fails the step; a bounded
    /// wait, never a retry of the step.
    private func waitWhileBusy(_ t: PlanTransport) async throws {
        for _ in 0..<200 {
            let answer = try await t.control(DFURequest(requestType: 0xA1, request: 3, value: 0, index: interface, length: 6))
            guard answer.count == 6, answer[0] == 0, answer[4] != 10 else { throw Failed() }
            if answer[4] != 4 { return }  // not dfuDNBUSY
            let ms = UInt64(answer[1]) | UInt64(answer[2]) << 8 | UInt64(answer[3]) << 16
            try? await Task.sleep(for: .milliseconds(ms))
        }
        throw Failed()
    }

    private func toIdle(_ t: PlanTransport) async throws {
        let answer = try await t.control(DFURequest(requestType: 0xA1, request: 3, value: 0, index: interface, length: 6))
        guard answer.count == 6 else { throw Failed() }
        if answer[4] == 10 { _ = try await t.control(DFURequest(requestType: 0x21, request: 4, value: 0, index: interface)) }
        else if answer[4] != 2 { _ = try await t.control(DFURequest(requestType: 0x21, request: 6, value: 0, index: interface)) }
    }
}

/// The guard in front of the chip for a write: read-only requests, and only the plan's own erases, pointers and blocks.
/// Anything else is refused before it is sent.
public final class PlanTransport: DFUTransport, @unchecked Sendable {
    public struct Refused: Error {}
    let inner: any DFUTransport
    let plan: WritePlan
    let transferSize: Int
    private var sector: WritePlan.Sector?

    public init(_ inner: any DFUTransport, plan: WritePlan, transferSize: Int = 2048) {
        self.inner = inner
        self.plan = plan
        self.transferSize = transferSize
    }

    public func control(_ r: DFURequest) async throws -> [UInt8] {
        guard allowed(r) else { throw Refused() }
        return try await inner.control(r)
    }

    private func allowed(_ r: DFURequest) -> Bool {
        guard r.requestType == 0x21, r.request == 1 else { return r.isReadOnly }
        if r.value == 0 {
            guard r.data.count == 5 else { return false }
            let a = UInt32(r.data[1]) | UInt32(r.data[2]) << 8 | UInt32(r.data[3]) << 16 | UInt32(r.data[4]) << 24
            switch r.data[0] {
            case 0x41: return plan.sectors.contains { $0.address == a }
            case 0x21:
                sector = plan.sectors.first { $0.address == a }
                return true
            default: return false
            }
        }
        guard r.value >= 2, let sector, !r.data.isEmpty, r.data.count <= transferSize else { return false }
        let offset = (Int(r.value) - 2) * transferSize
        return offset + r.data.count <= sector.bytes.count && Array(sector.bytes[offset..<(offset + r.data.count)]) == r.data
    }
}
