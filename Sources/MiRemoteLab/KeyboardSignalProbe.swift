// Xiaomi Remote Lab — GPL-3.0.
import Foundation
import IOKit.hid
import IOKit.hidsystem

// Short-lived modifier fallback for physical keyboards, only during recording.
// Never used to guess a logical shortcut from a physical key's position.
final class KeyboardSignalProbe {
    var log: (String) -> Void = { _ in }
    var modifier: (UInt16, Bool) -> Void = { _,_ in }
    var ordinaryKeyDown: () -> Void = {}
    private var manager: IOHIDManager?
    private var states: [UInt16: Bool] = [:]
    private var source: IOHIDDevice?
    private var ambiguous = false
    func start() {
        stop()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0); manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 6] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, result, _, _ in
            guard let context else { return }
            let probe = Unmanaged<KeyboardSignalProbe>.fromOpaque(context).takeUnretainedValue()
            probe.log("键盘原始信号监听连接：\(result)")
        }, context)
        IOHIDManagerRegisterInputValueCallback(m, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            let probe = Unmanaged<KeyboardSignalProbe>.fromOpaque(context).takeUnretainedValue()
            guard probe.manager != nil else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == 7 else { return }
            let device = IOHIDElementGetDevice(element)
            let vendor = IOHIDDeviceGetProperty(device,kIOHIDVendorIDKey as CFString) as? NSNumber
            let product = IOHIDDeviceGetProperty(device,kIOHIDProductIDKey as CFString) as? NSNumber
            let transport = IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String
            guard !(vendor?.intValue == 0x2717 && product?.intValue == 0x32B8), transport != "Virtual" else { return }
            let usage = UInt16(truncatingIfNeeded: IOHIDElementGetUsage(element))
            // Only modifier/menu keys are logged; ordinary key contents are ignored.
            let down = IOHIDValueGetIntegerValue(value) != 0
            if down, probe.source == nil { probe.source = device }
            if let source = probe.source, !CFEqual(source,device) {
                if down { probe.ambiguous = true; probe.ordinaryKeyDown() }
                return
            }
            guard (0xE0...0xE7).contains(usage) || usage == 0x65 else {
                if down && usage >= 4 { probe.ordinaryKeyDown() }
                return
            }
            guard probe.states[usage] != down, down || probe.states[usage] != nil else { return }
            probe.states[usage] = down
            probe.modifier(usage, down)
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, 0)
        if result != kIOReturnSuccess { log("键盘原始信号监听不可用：\(result)"); stop() }
    }
    func hasUnmodifiedKeyboardService() -> Bool {
        guard let source, !ambiguous,
              let vendor = IOHIDDeviceGetProperty(source,kIOHIDVendorIDKey as CFString) as? NSNumber,
              let product = IOHIDDeviceGetProperty(source,kIOHIDProductIDKey as CFString) as? NSNumber,
              let location = IOHIDDeviceGetProperty(source,kIOHIDLocationIDKey as CFString) as? NSNumber else { return false }
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        return withExtendedLifetime(client) {
            let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
            let targets = services.filter { service in
                (IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? NSNumber) == vendor &&
                (IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? NSNumber) == product &&
                (IOHIDServiceClientCopyProperty(service, kIOHIDLocationIDKey as CFString) as? NSNumber) == location
            }
            guard !targets.isEmpty else { return false }
            return targets.allSatisfy { service in
                ["UserKeyMapping", "HIDKeyboardModifierMappingPairs"].allSatisfy { name in
                    guard let value = IOHIDServiceClientCopyProperty(service, name as CFString) else { return true }
                    return (value as? NSArray)?.count == 0
                }
            }
        }
    }
    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        manager = nil; states = [:]; source = nil; ambiguous = false
    }
}
