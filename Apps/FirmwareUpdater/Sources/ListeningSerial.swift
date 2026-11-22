import Darwin
import DeviceFinder
import Foundation

/// Listens to a deck panel's serial port (#685): opened non-blocking, DTR and RTS cleared together in one call so the
/// auto-reset circuit never sees one without the other. At the speed asked: 921600 since #667, 115200 before. The
/// only write is the finder's question (#715, "version\n"), once the port is set up; with none it opens read-only.
struct ListeningSerial: PanelSerial {
    func listen(on port: String, baud: Int, for seconds: Double, asking question: String?) async -> Listened {
        await Task.detached { Self.read(port, baud, seconds, question) }.value
    }

    /// IOSSIOSPEED (IOKit/serial/ioss.h, _IOW('T', 2, speed_t)): sets a speed termios has no B constant for.
    private static let ioSSIOSpeed: UInt = 0x8008_5402

    private static func read(_ port: String, _ baud: Int, _ seconds: Double, _ question: String?) -> Listened {
        let fd = open(port, (question == nil ? O_RDONLY : O_RDWR) | O_NOCTTY | O_NONBLOCK)
        // DeckBridge holds the port with TIOCEXCL while it sends over the USB cable: the open fails busy.
        guard fd >= 0 else { return errno == EBUSY ? .busy : .lines([]) }
        defer { close(fd) }
        var lines: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIC, &lines)
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { return .lines([]) }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CREAD | CLOCAL)
        options.c_cflag &= ~tcflag_t(HUPCL)  // no DTR drop on close
        cfsetspeed(&options, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { return .lines([]) }
        var speed = speed_t(baud)
        guard ioctl(fd, ioSSIOSpeed, &speed) == 0 else { return .lines([]) }
        if let question {
            let bytes = Array(question.utf8)
            guard write(fd, bytes, bytes.count) == bytes.count else { return .lines([]) }
            tcdrain(fd)
        }

        var text = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { text.append(contentsOf: buffer[0..<count]) } else { usleep(20_000) }
        }
        return .lines(String(decoding: text, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) })
    }
}
