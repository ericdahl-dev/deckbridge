import Foundation
import IOKit
import IOKit.serial

/// Yields when a USB device or a serial port arrives or leaves (#688), so the app looks again by itself after a
/// driver install and a replug. Listens to the I/O Registry only; opens nothing. Lives as long as the app.
final class IOKitUSBChanges: @unchecked Sendable {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []

    init() {
        (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        // The serial port shows up a moment after the USB device, once the driver has loaded: watch both.
        for (service, kind) in [("IOUSBHostDevice", kIOFirstMatchNotification), ("IOUSBHostDevice", kIOTerminatedNotification),
                                (kIOSerialBSDServiceValue, kIOFirstMatchNotification), (kIOSerialBSDServiceValue, kIOTerminatedNotification)] {
            var iterator: io_iterator_t = 0
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = IOServiceAddMatchingNotification(port, kind, IOServiceMatching(service), { context, iterator in
                guard let context else { return }
                IOKitUSBChanges.drain(iterator)
                Unmanaged<IOKitUSBChanges>.fromOpaque(context).takeUnretainedValue().continuation.yield()
            }, context, &iterator)
            guard result == KERN_SUCCESS else { continue }
            // Draining arms the notification; what is already plugged in was read by the first look.
            Self.drain(iterator)
            iterators.append(iterator)
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
        continuation.finish()
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
    }
}
