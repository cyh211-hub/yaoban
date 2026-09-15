// Yaoban — GPL-3.0.
import Foundation

// Factory templates never read a developer's home folder. Editable user copies
// and the user's Default remain independent of these versioned definitions.
enum BuiltInPreset: String, CaseIterable {
    case codex, ppt, appleCodex, applePPT
    var id: String {
        switch self {
        case .appleCodex,.applePPT: return "builtin.\(rawValue).v2"
        case .codex,.ppt: return "builtin.\(rawValue).v1"
        }
    }
    var modelID: String { switch self { case .codex,.ppt: return RemoteModel.xiaomi.id; case .appleCodex,.applePPT: return RemoteModel.apple.id } }
    static func modelID(forKnownID id: String) -> String? {
        if let preset = allCases.first(where:{ $0.id == id }) { return preset.modelID }
        if ["builtin.appleCodex.v1","builtin.applePPT.v1"].contains(id) { return RemoteModel.apple.id }
        return nil
    }
    var name: String { switch self { case .codex,.appleCodex: return "Codex"; case .ppt,.applePPT: return "PPT" } }
    var detail: String {
        if self == .appleCodex { return "Apple：圆盘中心换行／长按发送，播放键发送／长按 Esc，TV 长按截图；侧边语音映射右 Command，遥控器收音待适配。" }
        if self == .applePPT { return "Apple：圆盘中心推进，方向翻页，播放键开始放映，返回退出，静音键切换黑屏。" }
        return self == .codex
            ? "沿用 Codex 工作键位，包含短按、长按和连发；麦克风对应右 Command。"
            : "适用于 Mac 版 PowerPoint。OK 推进，方向键翻页，电源开始放映，返回退出，菜单切换黑屏。"
    }
    var configuration: MappingConfiguration {
        switch self {
        case .appleCodex:
            var result = RemoteButtonLayout.configuration(BuiltInPreset.codex.configuration,for:.apple)
            result.touch.mode = .hybrid
            result.bindings[RemoteButtonLayout.playPause] = [0x28]
            result.longBindings[RemoteButtonLayout.playPause] = [0x29]
            result.triggers[RemoteButtonLayout.playPause] = .shortLong
            result.bindings[RemoteButtonLayout.mute] = [0xE1,0xE3,0x08]
            result.longBindings[RemoteButtonLayout.mute] = [0xE3,0x1C]
            result.triggers[RemoteButtonLayout.mute] = .shortLong
            return result
        case .applePPT:
            var result = RemoteButtonLayout.configuration(BuiltInPreset.ppt.configuration,for:.apple)
            result.touch.mode = .hybrid
            result.bindings[RemoteButtonLayout.playPause] = [0xE3,0x28]
            result.bindings[RemoteButtonLayout.mute] = [0x05]
            return result
        case .codex:
            // Exact snapshot of the user's active configuration, 2026-09-11.
            return MappingConfiguration(bindings:[
                0x3E:[0xE7],0x28:[0xE2,0x28],0x66:[0x28],0xF1:[0x2A],
                0x52:[0x52],0x51:[0x51],0x50:[0x50],0x4F:[0x4F],
                0x4A:[0xE3,0x05],0x65:[0xE1,0xE3,0x08],0x80:[0xE0,0x2B],
                0x81:[0xE0,0xE1,0x2B],0x35:[0xE2,0xE3,0x05]],
                repeatEnabled:true,
                triggers:[0x28:.shortLong,0x66:.shortLong,0x35:.shortLong,
                          0x80:.shortLong,0x81:.shortLong,0x65:.shortLong,
                          0x4A:.shortLong,0x3E:.hold],
                longBindings: [0x28:[0x28],0x66:[0x29],0x35:[0xE1,0xE3,0x21],
                               0x80:[0xE3,0x06],0x81:[0xE3,0x19],
                               0x65:[0xE3,0x1C],0x4A:[0xE3,0x1D]],
                longPressDelay:0.6)
        case .ppt:
            // Microsoft PowerPoint for Mac, not Windows F5 shortcuts.
            // Explicit ordinary triggers prevent accidental multi-slide repeats.
            return MappingConfiguration(bindings:[
                0x28:[0x2C],0x66:[0xE3,0x28],0xF1:[0x29],0x3E:[0xE7],
                0x52:[0x4B],0x50:[0x4B],0x51:[0x4E],0x4F:[0x4E],
                0x80:[0x4B],0x81:[0x4E],0x65:[0x05],0x4A:[0x4A],0x35:[0xE1,0xE3,0x28]],
                repeatEnabled:false,
                triggers:Dictionary(uniqueKeysWithValues:RemoteReport.names.keys.map { ($0,.hold) }))
        }
    }
}

extension MappingLibrary {
    mutating func addBuiltIn(_ preset: BuiltInPreset, selecting: Bool) throws {
        let name = availableName(preset.name,for:preset.modelID)
        let id = profiles.contains { $0.id == preset.id } ? UUID().uuidString : preset.id
        profiles.append(MappingProfile(id:id,name:name,modelID:preset.modelID,configuration:preset.configuration))
        if selecting { selectedID = id }
        _ = try validated()
    }
    func availableName(_ base: String, for modelID: String) -> String {
        let names = Set(profiles(for:modelID).map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var suffix = 1
        while true {
            let ending = "（内置 \(suffix)）"
            let candidate = String(base.prefix(max(1,40 - ending.count))) + ending
            if !names.contains(candidate.lowercased()) { return candidate }
            suffix += 1
        }
    }
    mutating func installBuiltInsIfNeeded() throws {
        for preset in BuiltInPreset.allCases where !installedPresetIDs.contains(preset.id) {
            if let index = profiles.firstIndex(where:{ $0.id == preset.id }) {
                // Exact factory IDs are the only legacy profiles that can be
                // attributed without device evidence.
                profiles[index].modelID = preset.modelID
                installedPresetIDs.insert(preset.id)
            } else if profiles.count < 100 {
                try addBuiltIn(preset,selecting:false)
                installedPresetIDs.insert(preset.id)
            }
        }
    }
}
