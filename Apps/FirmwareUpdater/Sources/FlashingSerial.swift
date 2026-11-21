import Darwin
import Foundation
import PanelFlasher

/// Opens a deck panel's serial port for flashing (#687). Exclusive (TIOCEXCL): DeckBridge, which holds the cable the
/// same way while it sends over it (#667), makes the open fail with EBUSY, and nothing else can open it mid-flash.
struct FlashingSerialOpener: LineOpener {
    func open(_ port: String) async throws -> any BootloaderLine {
        try FlashingSerial(port: port)
    }
}

/// The panel's serial port as the flasher's line. Both lines are cleared right after the open, before the flasher's
/// reset sequence, and DTR and RTS are only ever set together in one TIOCMSET, so the CrowPanel's auto-reset circuit
/// never sees one move alone. Closing leaves both off (HUPCL cleared, no drop on close), so the panel keeps running.
actor FlashingSerial: BootloaderLine {
    struct PortError: Error { let call: String; let code: Int32 }

    /// IOSSIOSPEED from IOKit/serial/ioss.h, _IOW('T', 2, speed_t): sets a speed termios has no constant for (921600).
    private static let iossioSpeed: UInt = 0x8008_5402
    private var fd: Int32

    init(port: String) throws {
        let fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 { throw errno == EBUSY ? FlashError.portBusy : PortError(call: "open", code: errno) }
        guard ioctl(fd, TIOCEXCL) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw code == EBUSY ? FlashError.portBusy : PortError(call: "TIOCEXCL", code: code)
        }
        var both: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIC, &both)
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw PortError(call: "tcgetattr", code: code)
        }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CREAD | CLOCAL)
        options.c_cflag &= ~tcflag_t(HUPCL | CRTSCTS)
        cfsetspeed(&options, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw PortError(call: "tcsetattr", code: code)
        }
        tcflush(fd, TCIOFLUSH)
        self.fd = fd
    }

    func setLines(dtr: Bool, rts: Bool) async throws {
        var bits: Int32 = 0
        guard ioctl(fd, TIOCMGET, &bits) == 0 else { throw FlashError.lineLost }
        bits &= ~(TIOCM_DTR | TIOCM_RTS)
        if dtr { bits |= TIOCM_DTR }
        if rts { bits |= TIOCM_RTS }
        guard ioctl(fd, TIOCMSET, &bits) == 0 else { throw FlashError.lineLost }
    }

    /// A write that can't finish in this long is a lost line: the largest frame (a 1 KB block, escaped) takes about
    /// 25 ms at 921600 and 200 ms at 115200.
    private static let writeDeadline = Duration.seconds(2)

    func write(_ bytes: [UInt8]) async throws {
        let deadline = ContinuousClock.now + Self.writeDeadline
        var sent = 0
        while sent < bytes.count {
            guard ContinuousClock.now < deadline else { throw FlashError.lineLost }
            let count = bytes[sent...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                sent += count
            } else if count < 0 && errno == EAGAIN {
                var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&ready, 1, 100)
            } else {
                throw FlashError.lineLost
            }
        }
        // tcdrain blocks until sent, with no timeout of its own; the bytes are already in the driver, which a
        // stuck driver (WCH's after a re-enumeration, tools/deck-panel/README.md) would hold forever. Not called.
    }

    func read(timeout: Double) async throws -> [UInt8] {
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let woke = poll(&ready, 1, Int32(timeout * 1000))
        if woke < 0 || ready.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw FlashError.lineLost }
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                out += buffer[0..<count]
            } else if count < 0 && errno != EAGAIN {
                throw FlashError.lineLost  // ENXIO after an unplug, say
            } else {
                break
            }
        }
        return out
    }

    func setSpeed(_ baud: Int) async throws {
        var speed = speed_t(baud)
        guard ioctl(fd, Self.iossioSpeed, &speed) == 0 else { throw FlashError.lineLost }
    }

    /// The whole time even when the task is cancelled (BootloaderLine.pause): not Task.sleep, which returns at once
    /// then and would cut the reset pulse to a millisecond.
    func pause(_ seconds: Double) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() }
        }
    }

    func close() async {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}
