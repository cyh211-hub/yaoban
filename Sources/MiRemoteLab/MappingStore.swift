// Xiaomi Remote Lab — GPL-3.0.
import Foundation
import Darwin

// One location for installed and development builds. The old workspace file is
// consulted only on first migration; it never overrides an existing saved file.
final class MappingStore {
    struct Loaded {
        let library: MappingLibrary
        let notice: String
        var configuration: MappingConfiguration { library.selected.configuration }
    }
    private struct Document: Codable {
        var version = 9
        let selectedID: String
        let profiles: [ProfileRecord]
        var installedPresetIDs: [String]? = nil
    }
    private struct ProfileRecord: Codable {
        let id: String
        let name: String
        var modelID: String? = nil
        let bindings: [String: [UInt16]]
        var combinations: [RemoteCombination]? = nil
        var repeatEnabled: Bool? = nil
        var triggers: [String: ActionTrigger]? = nil
        var longBindings: [String: [UInt16]]? = nil
        var longPressDelay: Double? = nil
        var touch: RemoteTouchSettings? = nil
    }
    private struct Version: Decodable { let version: Int }
    private struct VersionOne: Decodable { let bindings: [String: [UInt16]] }
    enum StoreError: LocalizedError {
        case newerVersion, invalidKey, verificationFailed
        var errorDescription: String? {
            switch self {
            case .newerVersion: return "设置来自更高版本，已保留原文件，请使用新版程序。"
            case .invalidKey: return "设置中的遥控器键位无法识别。"
            case .verificationFailed: return "设置写入后的核对失败，未确认保存。"
            }
        }
    }
    let directory: URL
    let legacyDirectory: URL?
    var url: URL { directory.appendingPathComponent("按键设置.json") }
    var backupURL: URL { directory.appendingPathComponent("按键设置.backup.json") }
    var migrationBackupURL: URL { directory.appendingPathComponent("按键设置-升级长按前.json") }
    var modelMigrationBackupURL: URL { directory.appendingPathComponent("按键设置-型号隔离升级前.json") }
    private let fm = FileManager.default

    init(directory: URL, legacyDirectory: URL? = nil) {
        self.directory = directory; self.legacyDirectory = legacyDirectory
    }
    static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiRemoteLab", isDirectory: true)
    }
    private func encode(_ library: MappingLibrary) throws -> Data {
        let checked = try library.validated()
        guard checked.profiles.allSatisfy({ $0.configuration.combinations.isEmpty && !$0.configuration.triggers.values.contains(.release) }) else {
            throw PrivateFiles.error("遥控器组合已停用，请使用普通、长按连发或短按／长按。")
        }
        let document = Document(selectedID: checked.selectedID, profiles: checked.profiles.map { profile in
            ProfileRecord(id:profile.id,name:profile.name,modelID:profile.modelID,bindings:Dictionary(uniqueKeysWithValues:profile.configuration.bindings.map { (String($0.key),KeyboardKey.normalized($0.value)) }),combinations:profile.configuration.combinations,repeatEnabled:profile.configuration.repeatEnabled,triggers:Dictionary(uniqueKeysWithValues:profile.configuration.triggers.map { (String($0.key),$0.value) }),longBindings:Dictionary(uniqueKeysWithValues:profile.configuration.longBindings.map { (String($0.key),KeyboardKey.normalized($0.value)) }),longPressDelay:profile.configuration.longPressDelay,touch:profile.configuration.touch)
        }, installedPresetIDs: checked.installedPresetIDs.sorted())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }
    private func configuration(_ values: [String: [UInt16]]) throws -> MappingConfiguration {
        var bindings: [UInt16: [UInt16]] = [:]
        for (key, value) in values {
            guard let source = UInt16(key), String(source) == key else { throw StoreError.invalidKey }
            bindings[source] = value
        }
        return try MappingConfiguration(bindings: bindings).validated()
    }
    private func decode(_ data: Data) throws -> MappingLibrary {
        let decoder = JSONDecoder()
        let version = try decoder.decode(Version.self, from: data).version
        if version == 1 { return MappingLibrary(configuration: try configuration(decoder.decode(VersionOne.self, from: data).bindings)) }
        guard (2...9).contains(version) else { throw StoreError.newerVersion }
        let document = try decoder.decode(Document.self, from: data)
        return try MappingLibrary(selectedID: document.selectedID, profiles: document.profiles.map { record in
            var triggers: [UInt16:ActionTrigger] = [:]
            for (key,value) in record.triggers ?? [:] {
                guard let source = UInt16(key), String(source) == key else { throw StoreError.invalidKey }
                triggers[source] = value
            }
            var longBindings: [UInt16:[UInt16]] = [:]
            for (key,value) in record.longBindings ?? [:] {
                guard let source = UInt16(key), String(source) == key else { throw StoreError.invalidKey }
                longBindings[source] = value
            }
            let configuration = try MappingConfiguration(bindings:configuration(record.bindings).bindings,combinations:record.combinations ?? [],repeatEnabled:record.repeatEnabled ?? true,triggers:triggers,longBindings:longBindings,longPressDelay:record.longPressDelay ?? 0.6,touch:record.touch ?? .init()).validated()
            if version >= 5 && (!configuration.combinations.isEmpty || configuration.triggers.values.contains(.release)) {
                throw PrivateFiles.error("新版设置中含有已停用的遥控器组合。")
            }
            let knownModel = BuiltInPreset.modelID(forKnownID:record.id)
            let modelID = record.modelID ?? knownModel
            return MappingProfile(id:record.id,name:record.name,modelID:modelID,configuration:version < 5 ? configuration.migratingLegacyPressActions() : configuration)
        }, installedPresetIDs:Set(document.installedPresetIDs ?? [])).validated()
    }
    private func writeVerified(_ data: Data, to destination: URL) throws {
        try PrivateFiles.write(data, to: destination)
        guard try PrivateFiles.read(destination) == data else { throw StoreError.verificationFailed }
    }
    func load() throws -> Loaded {
        try PrivateFiles.ensureDirectory(directory)
        if fm.fileExists(atPath: url.path) {
            var data = try PrivateFiles.read(url)
            var notice = "已载入自动保存的设置"
            do { _ = try decode(data) }
            catch StoreError.newerVersion { throw StoreError.newerVersion }
            catch {
                guard fm.fileExists(atPath: backupURL.path) else { throw error }
                let backup = try PrivateFiles.read(backupURL)
                _ = try decode(backup)
                let preserved = directory.appendingPathComponent("按键设置-无法读取-\(UUID().uuidString).json")
                try PrivateFiles.write(data,to:preserved)
                try writeVerified(backup,to:url)
                data = backup
                notice = "设置文件无法读取，已从上一次保存的备份恢复；原文件已保留"
            }
            return try finishLoad(data,notice:notice)
        }
        if fm.fileExists(atPath: backupURL.path) {
            let data = try PrivateFiles.read(backupURL)
            _ = try decode(data)
            try writeVerified(data,to:url)
            return try finishLoad(data,notice:"设置文件缺失，已从上一次保存的备份恢复")
        }
        let configuration: MappingConfiguration
        let notice: String
        if let legacy = legacyDirectory?.appendingPathComponent("按键设置.json"), fm.fileExists(atPath: legacy.path) {
            let data = try PrivateFiles.read(legacy)
            configuration = try JSONDecoder().decode(MappingConfiguration.self, from:data).validated().migratingLegacyPressActions()
            if !fm.fileExists(atPath:migrationBackupURL.path) { try writeVerified(data,to:migrationBackupURL) }
            notice = "已迁移原来的按键设置，以后自动保存到本机应用设置目录"
        } else {
            configuration = MappingConfiguration()
            notice = "首次运行，已保存默认键位"
        }
        let library = MappingLibrary(configuration: configuration)
        try saveLibrary(library)
        return Loaded(library: library, notice: notice)
    }
    private func finishLoad(_ data: Data, notice: String) throws -> Loaded {
        let library = try decode(data)
        let version = try JSONDecoder().decode(Version.self,from:data).version
        if version < 8, !fm.fileExists(atPath:modelMigrationBackupURL.path) {
            try writeVerified(data,to:modelMigrationBackupURL)
        }
        guard version < 5 else { return Loaded(library:library,notice:notice) }
        // Keep the full pre-upgrade document separately from rolling backups.
        if !fm.fileExists(atPath:migrationBackupURL.path) { try writeVerified(data,to:migrationBackupURL) }
        try saveLibrary(library)
        return Loaded(library:library,notice:notice + " · 已升级长按设置，原单键保留，旧组合已备份并停用")
    }
    func save(_ configuration: MappingConfiguration) throws {
        var library = fm.fileExists(atPath: url.path) ? try decode(PrivateFiles.read(url)) : MappingLibrary(configuration: configuration)
        library.profiles[library.selectedIndex].configuration = configuration
        try saveLibrary(library)
    }
    // App startup adds factory copies once. It never rewrites an existing
    // Default, user profile, or active selection, including name collisions.
    func loadForApp() throws -> Loaded {
        let hasSettings = [url,backupURL,legacyDirectory?.appendingPathComponent("按键设置.json")]
            .compactMap { $0 }.contains { fm.fileExists(atPath:$0.path) }
        let loaded = try load()
        var library = loaded.library
        if !hasSettings {
            library = MappingLibrary(selectedID:BuiltInPreset.codex.id,profiles:[])
        }
        try library.installBuiltInsIfNeeded()
        if !hasSettings { try library.select(BuiltInPreset.codex.id,for:RemoteModel.xiaomi.id) }
        if library != loaded.library { try saveLibrary(library) }
        return Loaded(library:library,notice:!hasSettings
            ? "已准备内置 Codex 和 PPT 预设，当前使用 Codex"
            : library != loaded.library ? loaded.notice + " · 已加入内置预设，原键位和当前模式保留" : loaded.notice)
    }
    func saveLibrary(_ library: MappingLibrary) throws {
        let data = try encode(library)
        try PrivateFiles.ensureDirectory(directory)
        if fm.fileExists(atPath: url.path) {
            let previous = try PrivateFiles.read(url)
            _ = try decode(previous)
            try writeVerified(previous, to: backupURL)
        } else { try writeVerified(data, to: backupURL) }
        try writeVerified(data, to: url)
    }
    func validateForSaving(_ library: MappingLibrary) throws { _ = try encode(library) }
    // Re-read before changing one row so unrelated recent edits are not lost.
    func update(source: UInt16, keys: [UInt16]?) throws -> MappingConfiguration {
        var library = try load().library
        library.profiles[library.selectedIndex].configuration.bindings[source] = keys.map(KeyboardKey.normalized)
        if keys == nil { library.profiles[library.selectedIndex].configuration.triggers[source] = .hold }
        try saveLibrary(library)
        return library.selected.configuration
    }
    func updateLong(source: UInt16, keys: [UInt16]) throws -> MappingConfiguration {
        var library = try load().library
        library.profiles[library.selectedIndex].configuration.longBindings[source] = KeyboardKey.normalized(keys)
        try saveLibrary(library)
        return library.selected.configuration
    }
    func editProfiles(_ edit: (inout MappingLibrary) throws -> Void) throws -> MappingLibrary {
        var library = try load().library
        try edit(&library)
        try saveLibrary(library)
        return library
    }
    // Run explicitly once on upgrade; ordinary reads never replace a saved default.
    func adoptCurrentAsDefaultOnce() throws -> Loaded {
        let marker = directory.appendingPathComponent("default-snapshot-v04")
        let loaded = try load()
        guard !fm.fileExists(atPath: marker.path) else { return loaded }
        guard loaded.library.profiles.contains(where:{ $0.id == "default" }) else { return loaded }
        let updated = try editProfiles { library in
            let snapshot = library.selected.configuration
            let index = library.profiles.firstIndex { $0.id == "default" }!
            library.profiles[index].configuration = snapshot
        }
        try PrivateFiles.write(Data("done".utf8), to: marker)
        return Loaded(library: updated, notice: "已将当前模式的键位保存为默认，原模式继续保留")
    }
    func migrateRecoveryJournals(to diagnostics: URL) throws {
        try PrivateFiles.ensureDirectory(diagnostics)
        guard let legacyDirectory else { return }
        let marker = directory.appendingPathComponent("recovery-migrated-v1")
        guard !fm.fileExists(atPath: marker.path) else { return }
        for name in ["mapping-restore.json", "audio-input-restore.json"] {
            let source = legacyDirectory.appendingPathComponent("Diagnostics/" + name)
            let target = diagnostics.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: source.path) {
                try PrivateFiles.write(PrivateFiles.read(source), to: target)
            }
        }
        try PrivateFiles.write(Data("done".utf8), to: marker)
    }
}

// A second app copy must not restore the first copy's mappings or overwrite its
// settings. The kernel releases this lock even after a crash.
final class InstanceLease {
    private var descriptor: Int32 = -1
    func acquire(in directory: URL) throws -> Bool {
        if descriptor >= 0 { return true }
        try PrivateFiles.ensureDirectory(directory)
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { _ = try PrivateFiles.checked(fd) } catch { close(fd); throw error }
        guard fchmod(fd, 0o600) == 0 else { close(fd); throw PrivateFiles.error("无法保护实例锁。") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno; close(fd)
            if code == EWOULDBLOCK { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd; return true
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}
