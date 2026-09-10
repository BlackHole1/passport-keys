import Foundation
import IOKit
import IOKit.serial

nonisolated struct SerialPortInfo: Hashable, Sendable {
    let path: String
    let vendorID: Int
    let productID: Int
    let serialNumber: String?

    var displayName: String {
        (path as NSString).lastPathComponent
    }
}

/// 通过 IOKit 监听串口增删,只保留 Espressif(VID 0x303A)的 USB 串口。
/// 同一 VID 下也可能是其它 ESP32 开发板,是否为 Passport Keys 固件由 DeviceManager 握手确认。
final class SerialDeviceMonitor {
    static let espressifVendorID = 0x303A

    var onChange: (([SerialPortInfo]) -> Void)?

    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var lastPorts: [SerialPortInfo]?

    func start() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port,
                type,
                IOServiceMatching(kIOSerialBSDServiceValue),
                { context, iterator in
                    SerialDeviceMonitor.drain(iterator)
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<SerialDeviceMonitor>.fromOpaque(context).takeUnretainedValue().rescan()
                    }
                },
                context,
                &iterator
            )
            guard result == KERN_SUCCESS else { continue }
            // 必须先把迭代器读空,通知才会被激活。
            Self.drain(iterator)
            iterators.append(iterator)
        }
        rescan()
    }

    func stop() {
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        notificationPort = nil
        lastPorts = nil
    }

    func rescan() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        var ports: [SerialPortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = Self.property(service, kIOCalloutDeviceKey) as? String,
                  let vendorID = Self.searchProperty(service, "idVendor") as? Int,
                  vendorID == Self.espressifVendorID
            else {
                continue
            }
            ports.append(SerialPortInfo(
                path: path,
                vendorID: vendorID,
                productID: Self.searchProperty(service, "idProduct") as? Int ?? 0,
                serialNumber: Self.searchProperty(service, "USB Serial Number") as? String
            ))
        }
        ports.sort { $0.path < $1.path }

        guard ports != lastPorts else { return }
        lastPorts = ports
        onChange?(ports)
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            IOObjectRelease(object)
        }
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// USB 厂商信息挂在串口服务的祖先节点(IOUSBHostDevice)上,需要沿父链查找。
    private static func searchProperty(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
    }
}
