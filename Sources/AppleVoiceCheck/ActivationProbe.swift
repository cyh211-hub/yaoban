// GPL-3.0. A bounded, auxiliary-interface experiment, not the production Siri path.
// Protocol evidence: docs/2026-09-12-github-apple-mic-source-review.md.
import Foundation
import IOKit.hid
import Darwin

enum AppleVoiceActivationProbe {
    struct Outcome: Encodable {
        var auxiliaryInterfaces = 0
        var featureInterfaces = 0
        var openedInterfaces = 0
        var writeAttempts = 0
        var acceptedSubmissions = 0
        var openFailures = 0
        var writeFailures = 0
        var returnCodes: [Int32] = []
        var status = "no-eligible-interface"
        let inspectingOnly: Bool
        let remoteAudioConfirmed = false
        let inputSubscribed = false
        let systemSettingsChanged = false
    }

    private static func property(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func sameBinding(_ expected: BoundApple) -> Bool {
        guard let current = try? BoundApple.resolve() else { return false }
        return current.id == expected.id && current.identity == expected.identity && current.address == expected.address
    }

    // The CLI caller is additionally supervised by a normal-user five-second
    // deadline. No IOHIDManager, global input callback, or exclusive open is used.
    static func run(bound: BoundApple, inspectOnly: Bool) throws -> Outcome {
        guard getuid() != 0, sameBinding(bound) else { throw BoundApple.Failure.selectedUnavailable }
        var outcome = Outcome(inspectingOnly: inspectOnly)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            throw BoundApple.Failure.registryUnavailable
        }
        defer { IOObjectRelease(iterator) }
        var candidates: [IOHIDDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            // Filter before creating a user client: ordinary button/touch/audio
            // interfaces remain exclusively owned by the installed application.
            guard property(service, kIOHIDVendorIDKey) as? Int == 0x004C,
                  property(service, kIOHIDProductIDKey) as? Int == 0x0315,
                  property(service, kIOHIDPrimaryUsagePageKey) as? Int == 0x20,
                  let transport = property(service, kIOHIDTransportKey) as? String,
                  let identity = AppleRemoteIdentity.make(serial: property(service, kIOHIDSerialNumberKey) as? String,
                                                         location: nil, transport: transport),
                  identity == bound.identity else { continue }
            outcome.auxiliaryInterfaces += 1
            guard outcome.auxiliaryInterfaces <= AppleVoiceActivationPolicy.maximumInterfaces else {
                outcome.status = "unexpected-interface-count"; return outcome
            }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
                  let bluetooth = RemoteBluetoothDevice.resolve(device), bluetooth.isConnected(),
                  let address = bluetooth.addressString else { continue }
            let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []
            let features = Set(elements.filter { IOHIDElementGetType($0) == kIOHIDElementTypeFeature }
                .map { Int(IOHIDElementGetReportID($0)) })
            let candidate = AppleVoiceActivationPolicy.Interface(vendor: 0x004C, product: 0x0315,
                transport: transport, identity: identity, address: address, usagePage: 0x20, featureReportIDs: features)
            guard AppleVoiceActivationPolicy.isEligible(candidate, expectedIdentity: bound.identity,
                                                        expectedAddress: bound.address) else { continue }
            outcome.featureInterfaces += 1
            candidates.append(device)
        }
        guard !candidates.isEmpty else { return outcome }
        if inspectOnly { outcome.status = "eligible-interfaces-found"; return outcome }
        for device in candidates {
            // A switch or disconnect between discovery and an individual write
            // must stop the experiment. Do not retry on another remote.
            guard sameBinding(bound), let bluetooth = RemoteBluetoothDevice.resolve(device),
                  bluetooth.isConnected(), let address = bluetooth.addressString,
                  address.replacingOccurrences(of: "-", with: ":").uppercased() == bound.address else {
                outcome.status = "device-changed-or-disconnected"; return outcome
            }
            let opened = IOHIDDeviceOpen(device, 0)
            outcome.returnCodes.append(opened)
            guard opened == kIOReturnSuccess else {
                outcome.openFailures += 1; outcome.status = "open-rejected"; return outcome
            }
            outcome.openedInterfaces += 1
            defer { IOHIDDeviceClose(device, 0) }
            guard sameBinding(bound) else { outcome.status = "device-changed-or-disconnected"; return outcome }
            var bytes = AppleVoiceActivationPolicy.payload
            outcome.writeAttempts += 1
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature,
                                             CFIndex(AppleVoiceActivationPolicy.reportID), &bytes, bytes.count)
            outcome.returnCodes.append(result)
            guard result == kIOReturnSuccess else {
                outcome.writeFailures += 1; outcome.status = "submission-rejected"; return outcome
            }
            outcome.acceptedSubmissions += 1
        }
        // Local success is not evidence of remote acceptance, and this one-shot
        // probe is not synchronized to Siri-down. There is no guessed stop byte.
        outcome.status = "submitted-audio-unverified"
        return outcome
    }
}
