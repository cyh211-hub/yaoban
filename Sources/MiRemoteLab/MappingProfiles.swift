// Xiaomi Remote Lab — GPL-3.0.
import Foundation

struct MappingProfile: Codable, Equatable {
    let id: String
    var name: String
    // nil retains a pre-v8 profile whose model cannot yet be determined. It is
    // kept on disk but never offered in a device's preset chooser.
    var modelID: String?
    var configuration: MappingConfiguration

    init(id: String, name: String, modelID: String? = nil, configuration: MappingConfiguration) {
        self.id = id; self.name = name; self.modelID = modelID; self.configuration = configuration
    }

    // Both menus are already scoped to one model; do not append brand labels.
    // Keep old factory entries distinct without changing saved user data.
    var displayName: String {
        let oldApple = ["builtin.appleCodex.v1","builtin.applePPT.v1"].contains(id)
        var base = name
        if oldApple, base.hasSuffix(" · Apple") { base = String(base.dropLast(" · Apple".count)) }
        return base + (oldApple ? "（旧版）" : "")
    }
}

// Clearing creates this explicit draft. While it exists, button and touch edits
// change memory only; switching must save or discard the draft first.
struct PresetDraftSession: Equatable {
    let deviceID: UUID
    let profileID: String
    let originalConfiguration: MappingConfiguration
    var configuration: MappingConfiguration

    init(deviceID: UUID, profileID: String, configuration: MappingConfiguration, model: RemoteModel) {
        self.deviceID = deviceID; self.profileID = profileID; originalConfiguration = configuration
        var cleared = configuration
        let rows = RemoteButtonLayout.rows(for:model)
        cleared.bindings = Dictionary(uniqueKeysWithValues:rows.map { ($0,[]) })
        cleared.longBindings = [:]
        cleared.triggers = Dictionary(uniqueKeysWithValues:rows.map { ($0,.hold) })
        cleared.combinations = []
        cleared.touch = .init()
        self.configuration = cleared
    }
}

struct MappingLibrary: Codable, Equatable {
    var selectedID: String
    var profiles: [MappingProfile]
    var installedPresetIDs: Set<String> = []

    // Used when importing v1/single-configuration settings. Device evidence in
    // the coordinated v8 migration later assigns it without guessing.
    init(configuration: MappingConfiguration = MappingConfiguration()) {
        selectedID = "legacy.unassigned"
        profiles = [MappingProfile(id:selectedID,name:"保留的旧键位",configuration:configuration)]
    }
    init(selectedID: String, profiles: [MappingProfile], installedPresetIDs: Set<String> = []) {
        self.selectedID = selectedID; self.profiles = profiles; self.installedPresetIDs = installedPresetIDs
    }
    var selectedIndex: Int { profiles.firstIndex { $0.id == selectedID }! }
    var selected: MappingProfile { profiles[selectedIndex] }
    var unassignedProfiles: [MappingProfile] { profiles.filter { $0.modelID == nil } }
    func profiles(for modelID: String) -> [MappingProfile] { profiles.filter { $0.modelID == modelID } }
    func profile(id: String, for modelID: String) -> MappingProfile? { profiles.first { $0.id == id && $0.modelID == modelID } }
    func containsProfile(id: String, for modelID: String) -> Bool { profile(id:id,for:modelID) != nil }
    func fallbackProfile(for modelID: String) -> MappingProfile? {
        let preferred = modelID == RemoteModel.apple.id ? BuiltInPreset.appleCodex.id : BuiltInPreset.codex.id
        return profile(id:preferred,for:modelID) ?? profiles(for:modelID).first
    }
    func validated() throws -> MappingLibrary {
        guard installedPresetIDs.count <= 50, installedPresetIDs.allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
              !profiles.isEmpty, profiles.count <= 100,
              Set(profiles.map { $0.id }).count == profiles.count,
              profiles.contains(where: { $0.id == selectedID }) else { throw error("预设数据不完整，原文件已保留。") }
        var namesByModel: [String:Set<String>] = [:]
        for profile in profiles {
            guard !profile.id.isEmpty, profile.id.count <= 100,
                  profile.name == profile.name.trimmingCharacters(in:.whitespacesAndNewlines),
                  !profile.name.isEmpty, profile.name.count <= 40 else { throw error("预设名称为空或过长。") }
            let nameScope = profile.modelID ?? "<unassigned>"
            guard namesByModel[nameScope,default:[]].insert(profile.name.lowercased()).inserted else { throw error("同一型号的预设名称不能重复。") }
            if let modelID = profile.modelID {
                guard let model = RemoteModel.catalog.first(where:{ $0.id == modelID && $0.supported }) else { throw error("预设的遥控器型号无法识别。") }
                let rows = Set(RemoteButtonLayout.rows(for:model))
                guard profile.configuration.bindings.keys.allSatisfy(rows.contains),
                      profile.configuration.longBindings.keys.allSatisfy(rows.contains),
                      profile.configuration.triggers.keys.allSatisfy(rows.contains) else { throw error("预设含有其它型号的按键。") }
            }
            _ = try profile.configuration.validated()
        }
        return self
    }
    func error(_ text: String) -> Error { NSError(domain:"MappingProfiles",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
    mutating func select(_ id: String) throws {
        guard profiles.contains(where:{ $0.id == id }) else { throw error("这个预设已不存在，请重新打开设置。") }
        selectedID = id
    }
    mutating func select(_ id: String, for modelID: String) throws {
        guard containsProfile(id:id,for:modelID) else { throw error("这个预设不适用于当前遥控器。") }
        selectedID = id
    }
    mutating func duplicate(name: String, for modelID: String? = nil) throws {
        let owner = modelID ?? selected.modelID
        let profile = MappingProfile(id:UUID().uuidString,name:name.trimmingCharacters(in:.whitespacesAndNewlines),modelID:owner,configuration:selected.configuration)
        profiles.append(profile); selectedID = profile.id; _ = try validated()
    }
    mutating func renameSelected(_ name: String) throws {
        profiles[selectedIndex].name = name.trimmingCharacters(in:.whitespacesAndNewlines); _ = try validated()
    }
    mutating func deleteSelected() throws { try delete(selectedID) }
    mutating func delete(_ id: String) throws {
        guard let index = profiles.firstIndex(where:{ $0.id == id }) else { throw error("这个预设已不存在，请重新选择。") }
        guard profiles.count > 1 else { throw error("至少需要保留一个预设。") }
        let modelID = profiles[index].modelID
        if let modelID, profiles(for:modelID).count == 1 { throw error("每种遥控器至少需要保留一个预设。") }
        profiles.remove(at:index)
        if selectedID == id { selectedID = modelID.flatMap { fallbackProfile(for:$0)?.id } ?? profiles[0].id }
    }
}
