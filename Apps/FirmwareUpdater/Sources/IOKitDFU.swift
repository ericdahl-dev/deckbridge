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
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: 0x0483, productID: 0xDF11, bcdDevice: nil, interfaceNumber: 0, configurationValue: nil,
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
                name = (try? interface.__string(with: Int(index), languageID: 0x0409)) as String? ?? ""
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
