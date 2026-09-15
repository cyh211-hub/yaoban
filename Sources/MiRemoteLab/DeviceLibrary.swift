import Foundation

struct SavedRemote: Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var binding: RemoteBinding
    var enabled = true
    var profileID: String
    // nil appears only in pre-v3 device files and is filled by the coordinated
    // profile migration before normal editing starts.
    var startupProfileID: String? = nil
    var configuration: MappingConfiguration

    init(id: UUID = UUID(), name: String, binding: RemoteBinding, enabled: Bool = true,
         profileID: String, startupProfileID: String? = nil, configuration: MappingConfiguration) {
        self.id = id; self.name = name; self.binding = binding; self.enabled = enabled
        self.profileID = profileID; self.startupProfileID = startupProfileID ?? profileID
        self.configuration = configuration
    }
}

struct RetainedRemoteConfiguration: Codable, Equatable {
    var id: UUID
    var name: String
    var modelID: String
    var configuration: MappingConfiguration
}

struct RemoteDeviceLibrary: Codable, Equatable {
    var version = 4
    var selectedID: UUID?
    var devices: [SavedRemote] = []
    var retained: [RetainedRemoteConfiguration] = []
    var selected: SavedRemote? { devices.first { $0.id == selectedID } }
    func validated() throws -> Self {
        let boundHIDIdentities = devices.filter { $0.binding.isBound }.map { $0.binding.hidIdentity }
        guard (1...4).contains(version), devices.count <= 16, retained.count <= 100,
              Set(devices.map(\.id)).count == devices.count,
              Set(devices.compactMap { $0.binding.peripheralID }).count == devices.compactMap({ $0.binding.peripheralID }).count,
              Set(boundHIDIdentities).count == boundHIDIdentities.count,
              devices.isEmpty ? selectedID == nil : devices.contains(where: { $0.id == selectedID }) else {
            throw PrivateFiles.error("设备库不完整、包含重复设备或版本不兼容；原文件保留。")
        }
        for item in devices {
            _ = try item.binding.validated()
            guard Self.validName(item.name), !item.profileID.isEmpty, item.profileID.count <= 100,
                  item.startupProfileID.map({ !$0.isEmpty && $0.count <= 100 }) ?? true else { throw PrivateFiles.error("设备名称或预设记录无效。") }
            try Self.validateConfiguration(item.configuration)
        }
        guard Set(retained.map(\.id)).count == retained.count else { throw PrivateFiles.error("保留的键位记录重复。") }
        for item in retained {
            guard Self.validName(item.name), RemoteModel.catalog.contains(where: { $0.id == item.modelID && $0.supported }) else { throw PrivateFiles.error("保留的键位记录无效。") }
            try Self.validateConfiguration(item.configuration)
        }
        var upgraded = self; upgraded.version = 4
        return upgraded
    }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name.rangeOfCharacter(from:.controlCharacters) == nil
    }
    private static func validateConfiguration(_ configuration: MappingConfiguration) throws {
        _ = try configuration.validated()
        guard configuration.combinations.isEmpty, !configuration.triggers.values.contains(.release) else {
            throw PrivateFiles.error("设备键位含已停用的组合设置，请使用普通、短长按或连发。")
        }
    }
    mutating func remove(_ id: UUID) throws {
        guard let item = devices.first(where:{ $0.id == id }) else { return }
        // Never silently evict an old custom configuration at a storage limit.
        if !retained.contains(where:{ $0.id == id }) && retained.count >= 100 { throw PrivateFiles.error("已保留 100 份设备键位，请先另存需要的模式并整理保留记录。") }
        retained.removeAll { $0.id == id }
        retained.append(.init(id:id,name:item.name,modelID:item.binding.model.id,configuration:item.configuration))
        devices.removeAll { $0.id == id }
        if selectedID == id { selectedID = devices.first?.id }
    }
    mutating func reconcileProfiles(_ profiles: MappingLibrary, removedProfileIDs: Set<String> = []) {
        for i in devices.indices {
            let modelID = devices[i].binding.model.id
            let fallback = profiles.fallbackProfile(for:modelID)
            if let startup = devices[i].startupProfileID,
               profiles.containsProfile(id:startup,for:modelID) == false {
                devices[i].startupProfileID = fallback?.id
            } else if devices[i].startupProfileID == nil {
                devices[i].startupProfileID = profiles.containsProfile(id:devices[i].profileID,for:modelID) ? devices[i].profileID : fallback?.id
            }
            guard !profiles.containsProfile(id:devices[i].profileID,for:modelID),
                  let startupID = devices[i].startupProfileID,
                  let startup = profiles.profile(id:startupID,for:modelID) ?? fallback else { continue }
            let oldID = devices[i].profileID
            devices[i].profileID = startup.id
            // Deleting the loaded preset is an explicit request to return to the
            // device's startup preset. Migration repairs keep the snapshot intact.
            if removedProfileIDs.contains(oldID) {
                devices[i].configuration = RemoteButtonLayout.configuration(startup.configuration,for:devices[i].binding.model)
            }
        }
    }
    mutating func applyStartupProfiles(_ profiles: MappingLibrary) throws {
        // Only the selected device is started by this app session. Inactive
        // devices keep their remembered working snapshots until selected.
        for i in devices.indices where devices[i].id == selectedID {
            let model = devices[i].binding.model
            guard let startupID = devices[i].startupProfileID,
                  let preset = profiles.profile(id:startupID,for:model.id) else {
                throw PrivateFiles.error("遥控器的启动预设已不存在，原键位已保留。")
            }
            devices[i].profileID = startupID
            devices[i].configuration = RemoteButtonLayout.configuration(preset.configuration,for:model)
        }
    }
    // Switching is a service selection, not just an editor selection. At most one receiver runs.
    var activeID: UUID? { selected.flatMap { $0.enabled && $0.binding.isBound ? $0.id : nil } }
    mutating func selectDevice(_ id: UUID) {
        guard devices.contains(where:{ $0.id == id }) else { return }
        selectedID = id
        for i in devices.indices { devices[i].enabled = devices[i].id == id }
    }
    mutating func normalizeSelection() {
        guard let selectedID else { return }
        // An explicitly disabled selected device remains paused. Old multi-device records lose
        // only concurrent activation; every configuration and binding remains intact.
        for i in devices.indices where devices[i].id != selectedID { devices[i].enabled = false }
    }
}

final class RemoteDeviceStore {
    let directory: URL
    var url: URL { directory.appendingPathComponent("设备库.json") }
    init(directory: URL) { self.directory = directory }
    func load(migrating legacy: URL, profiles: MappingLibrary) throws -> RemoteDeviceLibrary {
        // Even an empty saved library is authoritative: don't resurrect a deleted
        // remote from the preserved pre-upgrade binding file.
        if FileManager.default.fileExists(atPath:url.path) {
            var library = try JSONDecoder().decode(RemoteDeviceLibrary.self,from:PrivateFiles.read(url)).validated()
            let original = library; library.normalizeSelection()
            if original != library { try save(library) }
            return library
        }
        var library = RemoteDeviceLibrary()
        if FileManager.default.fileExists(atPath:legacy.path) {
            let binding = try JSONDecoder().decode(RemoteBinding.self,from:PrivateFiles.read(legacy,limit:4096)).validated()
            let item = SavedRemote(name:binding.deviceName ?? binding.model.title,binding:binding,profileID:profiles.selectedID,configuration:profiles.selected.configuration)
            library.devices = [item]; library.selectedID = item.id
        }
        try save(library)
        return library
    }
    func save(_ library: RemoteDeviceLibrary) throws {
        let checked = try library.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(checked)
        if FileManager.default.fileExists(atPath:url.path) {
            let previous = try PrivateFiles.read(url)
            _ = try JSONDecoder().decode(RemoteDeviceLibrary.self,from:previous).validated()
            try PrivateFiles.write(previous,to:directory.appendingPathComponent("设备库.backup.json"))
        }
        try PrivateFiles.write(data,to:url)
        guard try PrivateFiles.read(url) == data else { throw PrivateFiles.error("设备保存核对失败。") }
    }
}

// Independent device engines share output ownership. Releasing one remote must
// not release a modifier or mouse button still held by another remote.
final class RemoteOutputOwnership {
    var emit: (UInt16,Bool) -> Void = { _,_ in }
    var pressAgain: (UInt16) -> Void = { _ in }
    private var held: [UUID:Set<UInt16>] = [:]
    func send(owner: UUID, key: UInt16, down: Bool) {
        let wasHeld = held.values.contains { $0.contains(key) }
        let owned = held[owner]?.contains(key) == true
        if down { held[owner,default:[]].insert(key) }
        else { held[owner]?.remove(key); if held[owner]?.isEmpty == true { held.removeValue(forKey:owner) } }
        let isHeld = held.values.contains { $0.contains(key) }
        if wasHeld != isHeld { emit(key,isHeld) }
        else if down && !owned && wasHeld, let definition = KeyboardKey.find(key),
                !definition.isModifier && (!definition.isMouse || definition.isScroll) { pressAgain(key) }
    }
    func release(_ owner: UUID) {
        for key in KeyboardKey.normalized(Array(held[owner] ?? [])).reversed() { send(owner:owner,key:key,down:false) }
    }
}

final class RemoteVoiceOwnership {
    private(set) var owner: UUID?
    func acquire(_ id: UUID) -> Bool {
        guard owner == nil || owner == id else { return false }
        owner = id; return true
    }
    @discardableResult func release(_ id: UUID) -> Bool {
        guard owner == id else { return false }; owner = nil; return true
    }
}
