import Foundation
import CryptoKit

enum AppleRemoteIdentity {
    static func make(serial: String?, location: UInt64?, transport: String?) -> String? {
        guard transport == "Bluetooth" || transport == "Bluetooth Low Energy" else { return nil }
        if let serial, !serial.isEmpty, serial.count <= 256 {
            return "apple3:" + SHA256.hash(data:Data(serial.utf8)).map { String(format:"%02x",$0) }.joined()
        }
        if let location, location > 0 { return "apple3loc:\(location)" }
        return nil
    }
    static func valid(_ value: String) -> Bool {
        if value.hasPrefix("apple3:") {
            let suffix = value.dropFirst(7)
            return suffix.count == 64 && suffix.allSatisfy { "0123456789abcdef".contains($0) }
        }
        guard value.hasPrefix("apple3loc:"), let location = UInt64(value.dropFirst(10)) else { return false }
        return location > 0 && "apple3loc:\(location)" == value
    }
}
