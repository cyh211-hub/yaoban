// Yaoban — GPL-3.0. Protocol references: docs/apple-remote-adapter.md.
// Research decoder only; enabling an Apple runtime still requires hardware validation.
import Foundation

enum AppleRemoteButton: String, CaseIterable, Codable {
    case power, up, down, left, right, center, back, tv, siri, playPause, mute, volumeUp, volumeDown
    var title: String {
        switch self {
        case .power: return "电源"
        case .up: return "上"
        case .down: return "下"
        case .left: return "左"
        case .right: return "右"
        case .center: return "圆盘中心"
        case .back: return "返回"
        case .tv: return "TV"
        case .siri: return "侧边语音"
        case .playPause: return "播放 / 暂停"
        case .mute: return "静音"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 −"
        }
    }
}

enum AppleButtonInput {
    static let vendorID = 0x004C
    static let productID = 0x0315

    static func matches(vendor: Int, product: Int, transport: String?) -> Bool {
        vendor == vendorID && product == productID &&
            ["Bluetooth Low Energy", "Bluetooth"].contains(transport ?? "")
    }

    // Only the reported Gen-3 button usages, not guesses for every vendor-defined element.
    // Coordinates, battery updates and audio report bytes cannot become a Siri press.
    static func decode(page: UInt32, usage: UInt32, value: Int) -> (AppleRemoteButton, Bool)? {
        guard value == 0 || value == 1 else { return nil }
        let button: AppleRemoteButton
        if page == 0x01 && usage == 0x86 { button = .back }
        else if page == 0x0C {
            switch usage {
            case 0x30: button = .power
            case 0x42: button = .up
            case 0x43: button = .down
            case 0x44: button = .left
            case 0x45: button = .right
            case 0x80: button = .center
            case 0x60: button = .tv
            case 0x04: button = .siri
            case 0xCD: button = .playPause
            case 0xE2: button = .mute
            case 0xE9: button = .volumeUp
            case 0xEA: button = .volumeDown
            default: return nil
            }
        } else { return nil }
        return (button, value == 1)
    }

    static func battery(_ value: Int?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }
}

// One state per physical remote. Interfaces own their individual elements, so removal of one
// mirrored interface cannot release a button still held on a sibling. No timers or output here.
struct AppleButtonState {
    struct Element: Hashable { let interface: UInt64; let cookie: UInt32 }
    struct Edge: Equatable { let button: AppleRemoteButton; let pressed: Bool }
    private var held: [Element: AppleRemoteButton] = [:]
    var buttons: Set<AppleRemoteButton> { Set(held.values) }

    mutating func receive(interface: UInt64, cookie: UInt32, page: UInt32,
                          usage: UInt32, value: Int) -> [Edge] {
        guard let (button, pressed) = AppleButtonInput.decode(page: page, usage: usage, value: value) else { return [] }
        let key = Element(interface: interface, cookie: cookie)
        let before = buttons
        if pressed { held[key] = button } else if held[key] == button { held[key] = nil }
        return edges(from: before)
    }
    mutating func remove(interface: UInt64) -> [Edge] {
        let before = buttons
        held = held.filter { $0.key.interface != interface }
        return edges(from: before)
    }
    mutating func reset() -> [Edge] {
        let before = buttons; held.removeAll()
        return edges(from: before)
    }
    private func edges(from before: Set<AppleRemoteButton>) -> [Edge] {
        let after = buttons
        return before.subtracting(after).sorted { $0.rawValue < $1.rawValue }.map { Edge(button:$0,pressed:false) }
            + after.subtracting(before).sorted { $0.rawValue < $1.rawValue }.map { Edge(button:$0,pressed:true) }
    }
}
