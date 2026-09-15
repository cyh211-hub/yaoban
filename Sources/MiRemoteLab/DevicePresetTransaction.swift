import Foundation

// A durable intent makes deleting a used preset and loading defaults on all its
// devices recoverable as one operation even if the app exits between two files.
struct DevicePresetTransaction: Codable {
    let version: Int
    let profiles: MappingLibrary
    let devices: RemoteDeviceLibrary
    struct Prepared {
        let profiles: MappingLibrary
        let devices: RemoteDeviceLibrary
        let notice: String?
    }
    static func url(_ store: MappingStore) -> URL { store.directory.appendingPathComponent("设备模式事务.json") }
    static func recover(store: MappingStore, deviceStore: RemoteDeviceStore) throws {
        let path = url(store)
        guard FileManager.default.fileExists(atPath:path.path) else { return }
        let transaction = try JSONDecoder().decode(Self.self,from:PrivateFiles.read(path))
        guard transaction.version == 1 else { throw PrivateFiles.error("设备模式事务来自未知版本，原文件保留。") }
        _ = try transaction.profiles.validated(); _ = try transaction.devices.validated()
        if transaction.devices.devices.contains(where:{ $0.startupProfileID == nil }) {
            guard transaction.devices.devices.allSatisfy({ item in transaction.profiles.profiles.contains(where:{ $0.id == item.profileID }) }) else {
                throw PrivateFiles.error("旧事务中的设备引用了不存在的预设。")
            }
        } else { try validateReferences(profiles:transaction.profiles,devices:transaction.devices) }
        try store.saveLibrary(transaction.profiles)
        try deviceStore.save(transaction.devices)
        try FileManager.default.removeItem(at:path)
    }
    static func commit(profiles: MappingLibrary, devices: RemoteDeviceLibrary, store: MappingStore, deviceStore: RemoteDeviceStore) throws {
        guard !FileManager.default.fileExists(atPath:url(store).path) else { throw PrivateFiles.error("上次保存尚未完成，请重新启用以恢复保存。") }
        _ = try profiles.validated(); _ = try devices.validated()
        try store.validateForSaving(profiles)
        try validateReferences(profiles:profiles,devices:devices)
        let transaction = Self(version:1,profiles:profiles,devices:devices)
        try PrivateFiles.write(JSONEncoder().encode(transaction),to:url(store))
        try recover(store:store,deviceStore:deviceStore)
    }

    private static func validateReferences(profiles: MappingLibrary, devices: RemoteDeviceLibrary) throws {
        guard devices.devices.allSatisfy({ item in
            let modelID = item.binding.model.id
            return profiles.containsProfile(id:item.profileID,for:modelID)
                && item.startupProfileID.map { profiles.containsProfile(id:$0,for:modelID) } == true
        }) else { throw PrivateFiles.error("设备引用了不存在或其他型号的预设，未保存事务。") }
    }

    // Call once after MappingStore.loadForApp and RemoteDeviceStore.load, before
    // creating runtimes. It performs v8 attribution and startup loading under the
    // existing two-file forward-recovery transaction.
    static func prepareForLaunch(profiles originalProfiles: MappingLibrary,
                                 devices originalDevices: RemoteDeviceLibrary,
                                 store: MappingStore, deviceStore: RemoteDeviceStore) throws -> Prepared {
        var profiles = originalProfiles
        var devices = originalDevices
        var migrated = false

        // Preserve every unassigned source profile byte-for-byte. For each model
        // that actually referenced it, create an adapted owned copy and redirect
        // only those devices.
        for source in profiles.unassignedProfiles {
            let modelIDs = Set(devices.devices.filter { $0.profileID == source.id || $0.startupProfileID == source.id }.map { $0.binding.model.id })
            for modelID in modelIDs.sorted() {
                guard let model = RemoteModel.catalog.first(where:{ $0.id == modelID && $0.supported }) else { continue }
                let newID = UUID().uuidString
                let baseName = ["默认","默认预设","我的自定义"].contains(source.name) ? "保留的键位" : source.name
                let name = profiles.availableName(baseName,for:modelID)
                profiles.profiles.append(.init(id:newID,name:name,modelID:modelID,configuration:RemoteButtonLayout.configuration(source.configuration,for:model)))
                for i in devices.devices.indices where devices.devices[i].binding.model.id == modelID {
                    if devices.devices[i].profileID == source.id { devices.devices[i].profileID = newID }
                    if devices.devices[i].startupProfileID == source.id { devices.devices[i].startupProfileID = newID }
                }
                migrated = true
            }
        }

        try profiles.installBuiltInsIfNeeded()
        for i in devices.devices.indices {
            let model = devices.devices[i].binding.model
            if !profiles.containsProfile(id:devices.devices[i].profileID,for:model.id),
               let fallback = profiles.fallbackProfile(for:model.id) {
                devices.devices[i].profileID = fallback.id
                migrated = true
            }
            // A pre-v3 device snapshot can contain edits newer than its profile.
            // Give that exact snapshot an owned preset before startup loading.
            if devices.devices[i].startupProfileID == nil {
                let current = profiles.profile(id:devices.devices[i].profileID,for:model.id)
                let template = current.map { RemoteButtonLayout.configuration($0.configuration,for:model) }
                if template != devices.devices[i].configuration {
                    let base = "\(devices.devices[i].name) 的键位"
                    let name = profiles.availableName(String(base.prefix(40)),for:model.id)
                    let id = UUID().uuidString
                    profiles.profiles.append(.init(id:id,name:name,modelID:model.id,configuration:devices.devices[i].configuration))
                    devices.devices[i].profileID = id
                }
                devices.devices[i].startupProfileID = devices.devices[i].profileID
                migrated = true
            }
        }
        devices.reconcileProfiles(profiles)
        try devices.applyStartupProfiles(profiles)
        if let selected = devices.selected { profiles.selectedID = selected.profileID }
        else if profiles.profiles.first(where:{ $0.modelID != nil }) != nil,
                profiles.selected.modelID == nil { profiles.selectedID = profiles.profiles.first(where:{ $0.modelID != nil })!.id }

        _ = try profiles.validated(); _ = try devices.validated()
        if profiles != originalProfiles || devices != originalDevices {
            try commit(profiles:profiles,devices:devices,store:store,deviceStore:deviceStore)
        }
        return Prepared(profiles:profiles,devices:devices,notice:migrated ? "已按遥控器型号升级预设，原键位已保留" : nil)
    }
}
