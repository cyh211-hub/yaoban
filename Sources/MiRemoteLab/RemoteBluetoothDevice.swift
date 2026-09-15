import Foundation
import IOKit.hid
import IOBluetooth

enum RemoteBluetoothDevice {
    static func validAddress(_ value: String) -> Bool {
        let parts = value.replacingOccurrences(of:"-",with:":").split(separator:":",omittingEmptySubsequences:false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy { "0123456789abcdefABCDEF".contains($0) } }
    }
    static func displayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let name = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().trimmingCharacters(in:.whitespacesAndNewlines).prefix(80))
        return name.isEmpty ? nil : name
    }
    // The caller has already verified the bound HID identity. Only a nearby parent
    // bearing the same hardware serial may associate that HID with a Bluetooth address.
    // No paired-device enumeration, connection request or pairing mutation occurs here.
    static func resolve(_ device: IOHIDDevice) -> IOBluetoothDevice? {
        guard let serial = IOHIDDeviceGetProperty(device,kIOHIDSerialNumberKey as CFString) as? String,!serial.isEmpty else { return nil }
        var node = IOHIDDeviceGetService(device)
        guard IOObjectRetain(node) == KERN_SUCCESS else { return nil }
        defer { if node != 0 { IOObjectRelease(node) } }
        for _ in 0..<4 where node != 0 {
            func string(_ key: String) -> String? {
                IORegistryEntryCreateCFProperty(node,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String
            }
            if string(kIOHIDSerialNumberKey) == serial,let address = string("DeviceAddress"),validAddress(address) {
                return IOBluetoothDevice(addressString:address)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(node,kIOServicePlane,&parent) == KERN_SUCCESS else { break }
            IOObjectRelease(node); node = parent
        }
        return nil
    }
}
