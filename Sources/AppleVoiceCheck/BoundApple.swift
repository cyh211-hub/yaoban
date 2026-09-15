// GPL-3.0. Read-only selected-device lookup; never opens or subscribes to HID input.
import Foundation
import IOKit.hid
import IOBluetooth

struct BoundApple: Codable, Equatable {
    let id: String
    let identity: String
    let address: String
    let name: String
    enum Failure: String, Error { case unavailable, libraryUnavailable, selectedUnavailable, registryUnavailable, connectionUnavailable }


    static func resolve() throws -> BoundApple {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("MiRemoteLab/设备库.json")
        guard let data = try? Data(contentsOf: url) else { throw Failure.libraryUnavailable }
        guard data.count <= 1_048_576,
              let library = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = library["selectedID"] as? String, UUID(uuidString: id) != nil,
              let devices = library["devices"] as? [[String: Any]],
              let selected = devices.first(where: { $0["id"] as? String == id }),
              selected["enabled"] as? Bool == true,
              let binding = selected["binding"] as? [String: Any],
              binding["modelID"] as? String == "apple-siri-remote",
              let expected = binding["hidIdentity"] as? String,
              expected.hasPrefix("apple3:"), AppleRemoteIdentity.valid(expected) else { throw Failure.selectedUnavailable }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { throw Failure.registryUnavailable }
        defer { IOObjectRelease(iterator) }
        var addresses: Set<String> = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func property(_ node: io_registry_entry_t, _ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(node, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            // Registry properties suffice; do not create an IOHID user client just
            // to check identity from an administrator-launched experiment.
            guard property(service, kIOHIDProductIDKey) as? Int == 789,
                  let serial = property(service, kIOHIDSerialNumberKey) as? String,
                  let transport = property(service, kIOHIDTransportKey) as? String,
                  AppleRemoteIdentity.make(serial: serial, location: nil, transport: transport) == expected else { continue }
            var node = service
            IOObjectRetain(node)
            defer { if node != 0 { IOObjectRelease(node) } }
            var matchedAddress: String?
            for _ in 0..<4 where node != 0 {
                if property(node, kIOHIDSerialNumberKey) as? String == serial,
                   let address = property(node, "DeviceAddress") as? String,
                   RemoteBluetoothDevice.validAddress(address) { matchedAddress = address; break }
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
                IOObjectRelease(node); node = parent
            }
            guard let matchedAddress, let bluetooth = IOBluetoothDevice(addressString: matchedAddress), bluetooth.isConnected(),
                  let address = bluetooth.addressString, RemoteBluetoothDevice.validAddress(address) else { continue }
            addresses.insert(address.replacingOccurrences(of: "-", with: ":").uppercased())
        }
        guard addresses.count == 1, let address = addresses.first else { throw Failure.connectionUnavailable }
        return BoundApple(id: id, identity: expected, address: address,
                          name: RemoteBluetoothDevice.displayName(selected["name"] as? String) ?? "Apple Siri Remote")
    }
}
