import Foundation

// Eligibility for a narrowly scoped write probe, not proof of mic activation.
// The hardware caller must collect report IDs from Feature elements and
// revalidate the selected binding before sending any report.
struct AppleVoiceActivationPolicy {
    struct Interface {
        let vendor: Int
        let product: Int
        let transport: String
        let identity: String
        let address: String
        let usagePage: Int
        let featureReportIDs: Set<Int>
    }

    static let reportID = 0xFF
    static let payload: [UInt8] = [0xAF]
    static let maximumInterfaces = 4

    static func isEligible(_ candidate: Interface,
                           expectedIdentity: String,
                           expectedAddress: String) -> Bool {
        guard candidate.vendor == 0x004C, candidate.product == 0x0315,
              ["Bluetooth", "Bluetooth Low Energy"].contains(candidate.transport),
              validSerialIdentity(expectedIdentity),
              candidate.identity == expectedIdentity,
              let boundAddress = normalizedAddress(expectedAddress),
              let deviceAddress = normalizedAddress(candidate.address),
              deviceAddress == boundAddress,
              candidate.usagePage == 0x20,
              candidate.featureReportIDs.contains(reportID) else { return false }
        return true
    }

    // Matches AppleRemoteIdentity's serial-hash format. This isolated probe,
    // like BoundApple, intentionally does not accept location-only identities.
    private static func validSerialIdentity(_ identity: String) -> Bool {
        guard identity.hasPrefix("apple3:") else { return false }
        let digest = identity.dropFirst(7).utf8
        return digest.count == 64 && digest.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    // Same six-octet, ASCII-only address format used by RemoteBluetoothDevice;
    // kept local so the decision can be tested without loading HID/Bluetooth APIs.
    private static func normalizedAddress(_ address: String) -> [UInt8]? {
        let parts = address.replacingOccurrences(of: "-", with: ":")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard part.count == 2,
                  part.utf8.allSatisfy({ (48...57).contains($0) ||
                      (65...70).contains($0) || (97...102).contains($0) }),
                  let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
