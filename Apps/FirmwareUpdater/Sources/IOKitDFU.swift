import Foundation
import IOKit
import IOUSBHost
import UnitCheck

/// Devices in ST's update mode (0483:DF11), from the I/O Registry, and a transport to one (#692). Reads interface 0's
/// alt 0 name only (the flash layout); never the serial number. Every request goes through ReadOnlyTransport.
enum IOKitDFU {
    struct Found {
        let device: DFUDevice
        let service: io_service_t
    }

    static func devices() -> [Found] {
        // Interface matching needs bConfigurationValue with bInterfaceNumber: with nil it matches nothing (owner run, #709,
        // cos: 0 matches with nil, 1 with 1). The ST ROM bootloader has one configuration, 1.
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: 0x0483, productID: 0xDF11, bcdDevice: nil, interfaceNumber: 0, configurationValue: 1,
            interfaceClass: nil, interfaceSubclass: nil, interfaceProtocol: nil, speed: nil, productIDArray: nil)
            .takeRetainedValue()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [Found] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var name = ""
            if let interface = try? IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil) {
                let index = interface.interfaceDescriptor.pointee.iInterface
                // Raw first: the display chip's bootloader fails IOUSBHost's string read ("Failed to get descriptor") but
                // answers a full 255-byte GET_DESCRIPTOR (cos, on the owner's unit). The top panel chip answers both.
                name = rawString(index: index, interface: service)
                    ?? (try? interface.__string(with: Int(index), languageID: 0x0409)) as String? ?? ""
                interface.destroy()
            }
            var location: UInt32 = 0
            if let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "locationID" as CFString, kCFAllocatorDefault,
                                                           IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? NSNumber {
                location = value.uint32Value
            }
            found.append(Found(device: DFUDevice(path: String(format: "%08X", location), altNames: [name]), service: service))
        }
        return found
    }

    /// String descriptor `index` (US English) by a raw GET_DESCRIPTOR of 255 bytes to the interface's device. A read:
    /// no DFU request, nothing sent to the chip's flash. Nil when it fails or isn't a string descriptor.
    private static func rawString(index: UInt8, interface service: io_service_t) -> String? {
        guard index != 0 else { return nil }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        guard let device = try? IOUSBHostDevice(__ioService: parent, options: [], queue: nil, interestHandler: nil) else {
            return nil
        }
        defer { device.destroy() }
        let request = IOUSBDeviceRequest(bmRequestType: 0x80, bRequest: 6, wValue: 0x0300 | UInt16(index), wIndex: 0x0409,
                                         wLength: StringDescriptor.requestLength)
        let data = NSMutableData(length: Int(StringDescriptor.requestLength))!
        var transferred = 0
        guard (try? device.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 5)) != nil else {
            return nil
        }
        return StringDescriptor.text(Array(Data(referencing: data).prefix(transferred)))
    }
}

/// Control requests to a DFU interface over IOUSBHost. Wrapped in ReadOnlyTransport by the caller.
final class IOUSBHostDFU: DFUTransport, @unchecked Sendable {
    private let interface: IOUSBHostInterface

    init(service: io_service_t) throws {
        interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
    }

    deinit { interface.destroy() }

    func control(_ r: DFURequest) async throws -> [UInt8] {
        let toHost = r.requestType & 0x80 != 0
        let request = IOUSBDeviceRequest(bmRequestType: r.requestType, bRequest: r.request, wValue: r.value, wIndex: r.index,
                                         wLength: toHost ? r.length : UInt16(r.data.count))
        let data = toHost ? NSMutableData(length: Int(r.length))! : NSMutableData(bytes: r.data, length: r.data.count)
        var transferred = 0
        try interface.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 5)
        return toHost ? Array(Data(referencing: data).prefix(transferred)) : []
    }
}
