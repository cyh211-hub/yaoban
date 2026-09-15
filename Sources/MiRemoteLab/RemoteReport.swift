// Xiaomi Remote Lab — GPL-3.0. See LICENSE and THIRD_PARTY.md.
import Foundation

enum RemoteReport {
    static let names: [UInt16: String] = [0x66: "电源", 0x3E: "麦克风", 0x52: "上", 0x51: "下", 0x50: "左", 0x4F: "右", 0x28: "OK", 0xF1: "返回", 0x4A: "主页", 0x65: "菜单", 0x80: "音量+", 0x81: "音量−", 0x35: "TV"]
    static func name(_ keys: Set<UInt16>) -> String {
        keys.sorted().map { RemoteButtonLayout.names[$0] ?? String(format: "0x%04X", $0) }.joined(separator: " + ")
    }
    // The observed descriptor defines report 1 as three little-endian 16-bit usages.
    static func parse(id: UInt32, data: Data) -> Set<UInt16>? {
        guard id == 1 else { return nil }
        var b = Array(data)
        if b.count == 7 && b.first == 1 { b.removeFirst() }
        guard b.count == 6 else { return nil }
        let values = stride(from: 0, to: 6, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
        // HID error/rollover codes are not physical keys.
        guard !values.contains(where: { (1...3).contains($0) }) else { return nil }
        return Set(values.filter { $0 != 0 })
    }
}

enum WaveFile {
    static func encode(_ samples: [Int16], rate: UInt32 = 16_000) -> Data {
        var d = Data()
        func ascii(_ s: String) { d.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { d.append(UInt8(n & 255)); d.append(UInt8(n >> 8)) }
        func u32(_ n: UInt32) { u16(UInt16(n & 65535)); u16(UInt16(n >> 16)) }
        let size = UInt32(samples.count * 2)
        ascii("RIFF"); u32(36 + size); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        ascii("data"); u32(size)
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}
