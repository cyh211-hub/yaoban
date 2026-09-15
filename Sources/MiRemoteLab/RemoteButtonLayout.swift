import Foundation

// Persisted source IDs are application semantics, never Apple wire usages.
enum RemoteButtonLayout {
    static let playPause: UInt16 = 0xA001
    static let mute: UInt16 = 0xA002
    static let names = RemoteReport.names.merging([playPause:"播放 / 暂停",mute:"静音"]) { a,_ in a }
    static let xiaomiRows: [UInt16] = [0x35,0x3E,0x28,0xF1,0x80,0x81,0x52,0x51,0x50,0x4F,0x65,0x4A,0x66]
    // Power isn't offered until its native system sleep path can be controlled safely.
    static let appleRows: [UInt16] = [0x35,0x3E,0x28,0xF1,playPause,mute,0x80,0x81,0x52,0x51,0x50,0x4F]
    static func rows(for model: RemoteModel) -> [UInt16] { model == .apple ? appleRows : xiaomiRows }
    static func name(_ source: UInt16, model: RemoteModel) -> String {
        if model == .apple && source == 0x3E { return "侧边语音" }
        if model == .apple && source == 0x28 { return "圆盘中心" }
        return names[source] ?? "未知按键"
    }
    static func source(_ button: AppleRemoteButton) -> UInt16? {
        switch button {
        case .power: return nil
        case .up: return 0x52
        case .down: return 0x51
        case .left: return 0x50
        case .right: return 0x4F
        case .center: return 0x28
        case .back: return 0xF1
        case .tv: return 0x35
        case .siri: return 0x3E
        case .playPause: return playPause
        case .mute: return mute
        case .volumeUp: return 0x80
        case .volumeDown: return 0x81
        }
    }
    static func configuration(_ original: MappingConfiguration, for model: RemoteModel) -> MappingConfiguration {
        let sources = Set(rows(for:model))
        var result = original
        result.bindings = original.bindings.filter { sources.contains($0.key) }
        result.longBindings = original.longBindings.filter { sources.contains($0.key) }
        result.triggers = original.triggers.filter { sources.contains($0.key) }
        // Apple uses an exclusive HID path, so every button needs an explicit mapped/disabled state.
        if model == .apple {
            for source in sources where result.bindings[source] == nil { result.bindings[source] = [] }
        }
        return result
    }
}
