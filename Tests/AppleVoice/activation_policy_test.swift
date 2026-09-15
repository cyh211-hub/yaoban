#if APPLE_VOICE_ACTIVATION_TEST
import Foundation

@main
enum AppleVoiceActivationPolicyTests {
    private static var checks = 0
    private static let identity = "apple3:" + String(repeating: "a", count: 64)
    private static let address = "AB:CD:EF:12:34:56"

    private static func candidate(vendor: Int = 0x004C, product: Int = 0x0315,
                                  transport: String = "Bluetooth",
                                  identity: String = identity,
                                  address: String = address,
                                  usagePage: Int = 0x20,
                                  featureReportIDs: Set<Int> = [0xFF]) -> AppleVoiceActivationPolicy.Interface {
        .init(vendor: vendor, product: product, transport: transport,
              identity: identity, address: address, usagePage: usagePage,
              featureReportIDs: featureReportIDs)
    }

    private static func expect(_ actual: Bool, _ expected: Bool, _ label: String) {
        checks += 1
        guard actual == expected else {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
    }

    private static func eligible(_ value: AppleVoiceActivationPolicy.Interface,
                                 expectedIdentity: String = identity,
                                 expectedAddress: String = address) -> Bool {
        AppleVoiceActivationPolicy.isEligible(value,
                                              expectedIdentity: expectedIdentity,
                                              expectedAddress: expectedAddress)
    }

    static func main() {
        expect(eligible(candidate()), true, "Bound Gen-3 Bluetooth Feature interface")
        expect(eligible(candidate(transport: "Bluetooth Low Energy")), true, "BLE transport")
        expect(eligible(candidate(featureReportIDs: [0, 1, 0xFF, 0xFA])), true,
               "Other Feature reports do not invalidate the activation report")
        expect(AppleVoiceActivationPolicy.reportID == 0xFF, true, "Activation report ID")
        expect(AppleVoiceActivationPolicy.payload == [0xAF], true, "One-byte activation payload")
        expect(AppleVoiceActivationPolicy.maximumInterfaces == 4, true, "Bounded interface attempts")

        for transport in ["USB", "", "bluetooth", "Bluetooth ", "BluetoothLowEnergy", "SPI"] {
            expect(eligible(candidate(transport: transport)), false, "Reject transport \(transport)")
        }
        for vendor in [0, 0x004B, 0x004D, 0x2717, -1] {
            expect(eligible(candidate(vendor: vendor)), false, "Reject other vendor \(vendor)")
        }
        for product in [0, 0x0314, 0x0316, 0x0266, -1] {
            expect(eligible(candidate(product: product)), false, "Reject other model \(product)")
        }
        for page in [0, 1, 0x0C, 0xFF00, -1] {
            expect(eligible(candidate(usagePage: page)), false, "Reject unrelated interface \(page)")
        }
        for reports: Set<Int> in [[], [0], [0xFA], [0xFE], [0x100], [-1]] {
            expect(eligible(candidate(featureReportIDs: reports)), false,
                   "Reject interface without Feature 0xFF: \(reports)")
        }

        let validAddresses = ["AB:CD:EF:12:34:56", "ab:cd:ef:12:34:56",
                              "AB-CD-EF-12-34-56", "aB-cD:eF-12:34-56"]
        for supplied in validAddresses {
            for expected in validAddresses {
                expect(eligible(candidate(address: supplied), expectedAddress: expected), true,
                       "Equivalent normalized addresses")
            }
        }
        let invalidAddresses = ["", "ABCDEF123456", "AB:CD:EF:12:34", "AB:CD:EF:12:34:56:78",
                                "A:CD:EF:12:34:56", "0AB:CD:EF:12:34:56", "AG:CD:EF:12:34:56",
                                "AB::EF:12:34:56", ":AB:CD:EF:12:34:56", "AB:CD:EF:12:34:56:",
                                " AB:CD:EF:12:34:56", "AB:CD:EF:12:34:56\n", "ＡＢ:CD:EF:12:34:56",
                                "+A:CD:EF:12:34:56", "AB/CD/EF/12/34/56", "AB:CD:EF:12:34:5\u{0}"]
        for invalid in invalidAddresses {
            expect(eligible(candidate(address: invalid)), false, "Reject malformed device address")
            expect(eligible(candidate(), expectedAddress: invalid), false, "Reject malformed bound address")
            expect(eligible(candidate(address: invalid), expectedAddress: invalid), false,
                   "Matching malformed addresses remain invalid")
        }
        // Any changed octet denotes another remote, even when the HID identity agrees.
        let octets = [0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56]
        for index in octets.indices {
            for replacement in 0...255 where replacement != octets[index] {
                var other = octets
                other[index] = replacement
                let changed = other.map { String(format: "%02X", $0) }.joined(separator: ":")
                expect(eligible(candidate(address: changed)), false, "Reject different physical address")
            }
        }

        let otherIdentity = "apple3:" + String(repeating: "b", count: 64)
        expect(eligible(candidate(identity: otherIdentity)), false, "Reject another valid HID identity")
        expect(eligible(candidate(), expectedIdentity: otherIdentity), false, "Require current binding identity")
        expect(eligible(candidate(identity: "apple3loc:42"), expectedIdentity: "apple3loc:42"), false,
               "Location-only identity does not identify this probe's bound remote")
        let invalidIdentities = ["", "apple3:", "apple3:" + String(repeating: "a", count: 63),
                                 "apple3:" + String(repeating: "a", count: 65),
                                 "apple3:" + String(repeating: "A", count: 64),
                                 "apple3:" + String(repeating: "g", count: 64),
                                 "apple3loc:0", "apple3loc:042", "apple3loc:+42", "apple3loc:-1",
                                 "apple3loc:18446744073709551616", "xiaomi:42", identity + "\n"]
        for invalid in invalidIdentities {
            expect(eligible(candidate(identity: invalid)), false, "Reject malformed device identity")
            expect(eligible(candidate(), expectedIdentity: invalid), false, "Reject malformed bound identity")
            expect(eligible(candidate(identity: invalid), expectedIdentity: invalid), false,
                   "Matching malformed identities remain invalid")
        }
        print("PASS: \(checks) Apple microphone activation policy checks; no hardware accessed.")
    }
}
#endif
