// Xiaomi Remote Lab — GPL-3.0.
import Foundation

// Bluetooth SIG Battery Level (0x2A19): one unsigned byte, 0...100 percent.
// A missing, malformed or stale value is never presented as a live percentage.
struct RemoteBatteryReading: Equatable {
    private(set) var percent: Int?
    private(set) var updatedAt: Date?
    mutating func receive(_ data: Data, now: Date = Date()) -> Bool {
        guard data.count == 1, let byte = data.first, byte <= 100 else { return false }
        percent = Int(byte); updatedAt = now; return true
    }
    func current(connected: Bool, now: Date = Date()) -> Int? {
        guard connected, let updatedAt, (0...660).contains(now.timeIntervalSince(updatedAt)) else { return nil }
        return percent
    }
    func title(connected: Bool, now: Date = Date()) -> String {
        guard connected else { return "电量未知 · 未连接" }
        guard let value = current(connected:true,now:now) else { return "电量未知" }
        return value <= 20 ? "\(value)% · 电量低" : "\(value)%"
    }
    static func symbol(for value: Int?) -> String {
        guard let value else { return "battery.0percent" }
        return "battery.\(value > 87 ? 100 : value > 62 ? 75 : value > 37 ? 50 : value > 12 ? 25 : 0)percent"
    }
}
