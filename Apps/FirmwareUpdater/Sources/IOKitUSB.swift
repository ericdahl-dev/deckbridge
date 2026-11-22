import DeviceFinder
import Foundation
import IOKit
import IOKit.serial

/// The USB devices on the Mac, from the I/O Registry. Reads ids, the product name and a driver's serial port only:
/// never the serial number. Opens nothing.
struct IOKitUSB: USBDevices {
    func devices() async -> [USBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var found: [USBDevice] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard let vendor = Self.number(device, "idVendor"), let product = Self.number(device, "idProduct") else { continue }
            let name = IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String ?? ""
            // A driver's port sits below the device in the registry.
            let port = IORegistryEntrySearchCFProperty(device, kIOServicePlane, kIOCalloutDeviceKey as CFString,
                                                       kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String
            found.append(USBDevice(vendor: vendor, product: product, name: name, serialPort: port))
        }
        return found
    }

    private static func number(_ device: io_object_t, _ key: String) -> UInt16? {
        (IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)
            .map { $0.uint16Value }
    }
}
