/// One USB control request to a device in ST's update mode (DFU 1.1 with ST's DfuSe extensions).
public struct DFURequest: Sendable, Hashable {
    /// 0x21 host to device, 0xA1 device to host: class, interface.
    public let requestType: UInt8
    public let request: UInt8
    public let value: UInt16
    /// The DFU interface.
    public let index: UInt16
    /// What the host sends (host to device only).
    public let data: [UInt8]
    /// How many bytes the host asks for (device to host only).
    public let length: UInt16

    public init(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8] = [], length: UInt16 = 0) {
        self.requestType = requestType
        self.request = request
        self.value = value
        self.index = index
        self.data = data
        self.length = length
    }
}

/// The device in update mode, as control requests. The app's adapter is IOUSBHost; tests use a fake chip.
public protocol DFUTransport: Sendable {
    /// Sends one request; returns what the device answered (empty for host to device). Throws when the device is gone.
    func control(_ request: DFURequest) async throws -> [UInt8]
}

public enum DFUError: Error, Equatable {
    /// The device left update mode during the read.
    case left
}

/// Reads a chip's flash in update mode. It has no way to erase or write: the only download it sends is DfuSe's
/// set-address (command 0x21), as `dfu-util -s <address>:<length> -U` does (tools/lc6000-firmware/flash-day.sh).
public struct DFUReader: Sendable {
    let transport: any DFUTransport
    let interface: UInt16
    let transferSize: Int

    public init(transport: any DFUTransport, interface: UInt16 = 0, transferSize: Int = 2048) {
        self.transport = transport
        self.interface = interface
        self.transferSize = transferSize
    }

    public func read(address: UInt32, length: Int) async throws -> [UInt8] {
        try await toIdle()
        // DfuSe: block 0 of a download is a command; 0x21 sets the address pointer. Then a status poll runs it.
        let a = address
        _ = try await control(DFURequest(requestType: 0x21, request: Self.dnload, value: 0, index: interface,
                                         data: [0x21, UInt8(a & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a >> 16 & 0xFF), UInt8(a >> 24)]))
        _ = try await status()
        _ = try await status()
        try await abort()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        var block: UInt16 = 2 // DfuSe: upload blocks from 2 read from the pointer
        while bytes.count < length {
            let want = min(transferSize, length - bytes.count)
            let got = try await control(DFURequest(requestType: 0xA1, request: Self.upload, value: block, index: interface,
                                                   length: UInt16(transferSize)))
            if got.isEmpty { throw DFUError.left }
            bytes += got.prefix(want)
            block += 1
        }
        try await abort()
        return bytes
    }

    // DFU 1.1 requests.
    static let dnload: UInt8 = 1, upload: UInt8 = 2, getStatus: UInt8 = 3, clrStatus: UInt8 = 4, abortRequest: UInt8 = 6
    static let stateIdle: UInt8 = 2, stateError: UInt8 = 10

    /// As dfu-util starts: an error state is cleared, any other non-idle state aborted.
    private func toIdle() async throws {
        let state = try await status()
        if state == Self.stateError {
            _ = try await control(DFURequest(requestType: 0x21, request: Self.clrStatus, value: 0, index: interface))
        } else if state != Self.stateIdle {
            try await abort()
        }
    }

    /// GETSTATUS; the state byte.
    private func status() async throws -> UInt8 {
        let answer = try await control(DFURequest(requestType: 0xA1, request: Self.getStatus, value: 0, index: interface, length: 6))
        guard answer.count == 6 else { throw DFUError.left }
        return answer[4]
    }

    private func abort() async throws {
        _ = try await control(DFURequest(requestType: 0x21, request: Self.abortRequest, value: 0, index: interface))
    }

    private func control(_ request: DFURequest) async throws -> [UInt8] {
        do { return try await transport.control(request) } catch { throw DFUError.left }
    }
}

extension DFUError {
    /// What the owner reads.
    public var reason: String {
        switch self {
        case .left: "The unit left update mode during the read. Nothing was saved."
        }
    }
}

/// The guard in front of the app's real USB transport: anything but a read-only request is refused before it is sent.
public struct ReadOnlyTransport: DFUTransport {
    public struct Refused: Error {}
    let inner: any DFUTransport

    public init(_ inner: any DFUTransport) { self.inner = inner }

    public func control(_ request: DFURequest) async throws -> [UInt8] {
        guard request.isReadOnly else { throw Refused() }
        return try await inner.control(request)
    }
}

extension DFURequest {
    /// What dfu-util's DfuSe upload sends, and nothing else: GETSTATUS, GETSTATE, CLRSTATUS, ABORT, UPLOAD of a block,
    /// and the one download that sets the address pointer (DfuSe 0x21 and a 4-byte address, in block 0).
    var isReadOnly: Bool {
        switch (requestType, request) {
        case (0xA1, 3): data.isEmpty && length == 6
        case (0xA1, 5): data.isEmpty && length == 1
        case (0x21, 4), (0x21, 6): data.isEmpty && length == 0 && value == 0
        case (0xA1, 2): data.isEmpty && value >= 2
        case (0x21, 1): value == 0 && data.count == 5 && data[0] == 0x21
        default: false
        }
    }
}
