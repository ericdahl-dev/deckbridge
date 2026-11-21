// The deck panel's USB cable (#667, ADR 0011): finds the panel's serial port by its USB IDs, opens it while the cable's
// switch is on, and writes the feed's SLIP frames to it. Not unit-tested: the Kit tests the framing, the port choice,
// the Coordinator's cable feed and the status line; this is IOKit and termios, like UDP.swift.
import ControllerBridgeCore
import Darwin
import Foundation
import IOKit
import IOKit.serial

final class PanelCable: BytePort, @unchecked Sendable {
    /// The panel's console speed since #667, 8N1.
    static let baud: speed_t = 921_600
    /// While the switch is on, the port list is read this often: plugging in and unplugging recover by themselves.
    static let pollSeconds = 1.0
    /// A write that can't go out in this long is dropped: the panel resyncs at the next frame (its END).
    static let writeTimeoutMs: Int32 = 50

    // termios and ioctl requests Swift doesn't import (sys/ttycom.h, IOKit/serial/ioss.h).
    private static let tiocexcl: UInt = 0x2000_740D           // _IO('t', 13)
    private static let iossiospeed: UInt = 0x8008_5402        // _IOW('T', 2, speed_t)

    /// Every open, write and close, in order, off the main thread.
    private let io = DispatchQueue(label: "dev.ericdahl.ControllerBridge.panel-cable")
    // Owned by `io`.
    private var fd: Int32 = -1
    private var openPath: String?

    private let lock = NSLock()
    private var _state: CablePortState = .noPanel
    /// The port as last found, for Settings' status line.
    var state: CablePortState { lock.withLock { _state } }
    private func set(_ new: CablePortState) { lock.withLock { _state = new } }

    /// The port opened: the Coordinator sends the full snapshot on it. Called on the main queue.
    var onOpen: (() -> Void)?

    // Main thread.
    private var enabled = false
    private var timer: Timer?
    private var generation = 0

    /// The cable's switch. On: looks for the panel now and every second. Off: lets the port go once `flush` returns,
    /// so the goodbye already queued goes out first.
    func setEnabled(_ on: Bool, flush: @escaping @Sendable () -> Void) {
        guard on != enabled else { return }
        enabled = on
        generation += 1
        timer?.invalidate()
        timer = nil
        if on {
            look()
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in self?.look() }
        } else {
            let generation = generation
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                flush()
                DispatchQueue.main.async {
                    guard let self, !self.enabled, self.generation == generation else { return }
                    self.io.async { self.close(then: .noPanel) }
                }
            }
        }
    }

    /// Opens the panel's port if it's there and not open, and lets it go if it was unplugged.
    private func look() {
        let found = PanelPort.find(in: Self.ports())?.path
        io.async { [weak self] in
            guard let self else { return }
            if self.fd >= 0 {
                if found == self.openPath { return }
                self.close(then: .noPanel)
            }
            guard let found else { return self.set(.noPanel) }
            if self.open(found) {
                DispatchQueue.main.async { self.onOpen?() }
            }
        }
    }

    // MARK: On `io`

    private func open(_ path: String) -> Bool {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            set(errno == EBUSY ? .busy : .failed(String(cString: strerror(errno))))
            return false
        }
        // Exclusive: the Firmware Updater or a serial monitor gets EBUSY instead of mixing into the feed.
        guard ioctl(fd, Self.tiocexcl) == 0 else {
            let code = errno
            Darwin.close(fd)
            set(code == EBUSY ? .busy : .failed(String(cString: strerror(code))))
            return false
        }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        t.c_cflag &= ~tcflag_t(CRTSCTS | PARENB | CSTOPB)
        cfsetspeed(&t, speed_t(B115200))
        var speed = Self.baud
        guard tcsetattr(fd, TCSANOW, &t) == 0, ioctl(fd, Self.iossiospeed, &speed) == 0 else {
            let code = errno
            Darwin.close(fd)
            set(.failed(String(cString: strerror(code))))
            return false
        }
        self.fd = fd
        openPath = path
        set(.open)
        return true
    }

    private func close(then state: CablePortState) {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        openPath = nil
        set(state)
    }

    /// One frame, whole or, past the timeout, the rest dropped. Called on the feed's queue.
    func write(_ bytes: [UInt8]) {
        io.sync {
            guard fd >= 0 else { return }
            var at = 0
            while at < bytes.count {
                let wrote = bytes[at...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if wrote > 0 { at += wrote; continue }
                if wrote < 0, errno == EINTR { continue }
                if wrote < 0, errno == EAGAIN {
                    var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&waiting, 1, Self.writeTimeoutMs) > 0 { continue }
                    return
                }
                // Unplugged (ENXIO) or worse: let it go; the next look opens it again when it's back.
                let code = errno
                close(then: code == ENXIO ? .noPanel : .failed(String(cString: strerror(code))))
                return
            }
        }
    }

    // MARK: IOKit

    /// The Mac's serial ports, each with its USB IDs when it's a USB device.
    static func ports() -> [SerialPort] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator)
            == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [SerialPort] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            func usb(_ key: String) -> Int? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? Int
            }
            out.append(SerialPort(path: path, vendor: usb("idVendor"), product: usb("idProduct")))
        }
        return out
    }
}
