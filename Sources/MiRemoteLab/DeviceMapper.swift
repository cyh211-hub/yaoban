// Xiaomi Remote Lab — GPL-3.0. See THIRD_PARTY.md for API references.
import Foundation
import IOKit.hid
import IOKit.hidsystem

final class DeviceMapper {
    var log: (String) -> Void = { _ in }
    let journalURL: URL
    // An unscheduled simple client can retain its initial service list. Discover
    // afresh after connection changes, keeping each owner alive through all reads
    // and writes (including a nested restore during apply).
    private struct ServiceSnapshot {
        let owner: IOHIDEventSystemClient
        let devices: [(UInt64, IOHIDServiceClient)]
    }
    private var snapshots: [MappingSnapshot] = []
    private var active: [UInt16: UInt16]?
    private var activeIDs = Set<UInt64>()
    private var loadError: String?
    var targetIdentity: String?
    private let property = "UserKeyMapping" as CFString
    init(journalURL: URL) {
        self.journalURL = journalURL
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do { snapshots = try JSONDecoder().decode([MappingSnapshot].self, from: PrivateFiles.read(journalURL)) }
            catch { loadError = "映射恢复记录无法读取：\(error.localizedDescription)" }
        }
    }
    private func targets(allowUnbound: Bool = false) -> ServiceSnapshot {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        let devices: [(UInt64, IOHIDServiceClient)] = services.compactMap { service in
            let vendor = IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? NSNumber
            let product = IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? NSNumber
            guard vendor?.intValue == 0x2717, product?.intValue == 0x32B8,
                  let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value else { return nil }
            guard allowUnbound || (targetIdentity != nil && identity(service) == targetIdentity) else { return nil }
            return (id, service)
        }
        return ServiceSnapshot(owner: client, devices: devices)
    }
    private func identity(_ service: IOHIDServiceClient) -> String? {
        RemoteHIDIdentity.make(transport: IOHIDServiceClientCopyProperty(service, kIOHIDTransportKey as CFString) as? String,
            location: (IOHIDServiceClientCopyProperty(service, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint64Value)
    }
    func availableIdentities() -> [String] {
        let snapshot = targets(allowUnbound: true)
        return withExtendedLifetime(snapshot) {
            Array(Set(snapshot.devices.compactMap { identity($0.1) })).sorted()
        }
    }
    private func read(_ service: IOHIDServiceClient) throws -> [MappingPair] {
        guard let raw = IOHIDServiceClientCopyProperty(service, property) else { return [] }
        guard let items = raw as? [[String: NSNumber]] else { throw failure("系统返回了无法识别的映射格式。") }
        return try items.map { item in
            guard let src = item["HIDKeyboardModifierMappingSrc"], let dst = item["HIDKeyboardModifierMappingDst"] else { throw failure("系统按键映射数据不完整。") }
            return MappingPair(source: src.uint64Value, destination: dst.uint64Value)
        }
    }
    private func write(_ mappings: [MappingPair], to service: IOHIDServiceClient) throws {
        let value = mappings.map { ["HIDKeyboardModifierMappingSrc": NSNumber(value: $0.source), "HIDKeyboardModifierMappingDst": NSNumber(value: $0.destination)] }
        guard IOHIDServiceClientSetProperty(service, property, value as CFArray), try read(service) == mappings else {
            throw failure("系统未接受按键映射；请检查权限并重新检测。")
        }
    }
    private func saveJournal() throws {
        try PrivateFiles.write(JSONEncoder().encode(snapshots), to: journalURL)
    }
    private func failure(_ text: String) -> Error { NSError(domain: "DeviceMapper", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    // Apply only to the matched remote service. Each mutation is journaled first.
    @discardableResult func apply(_ desired: [UInt16: UInt16]) throws -> Bool {
        if let loadError { throw failure(loadError) }
        let snapshot = targets()
        defer { withExtendedLifetime(snapshot) {} }
        let devices = snapshot.devices
        let ids = Set(devices.map { $0.0 })
        guard devices.count <= 1 else { throw failure("发现多只同型号遥控器，请只保留目标遥控器连接。") }
        if active == desired, activeIDs == ids, !ids.isEmpty {
            for (_, service) in devices {
                let current = try read(service)
                for (source, target) in desired {
                    let pair = MappingPair(source: MappingPair.usage(source), destination: target == 0 ? 0 : MappingPair.usage(target))
                    guard current.filter({ $0.source == pair.source }) == [pair] else { throw failure("按键映射被其他程序改动，请点击重新检测。") }
                }
            }
            return true
        }
        try restore()
        guard !devices.isEmpty else { return false }
        let installed = desired.sorted { $0.key < $1.key }.map { MappingPair(source: MappingPair.usage($0.key), destination: $0.value == 0 ? 0 : MappingPair.usage($0.value)) }
        for (id, service) in devices {
            let current = try read(service)
            let sources = Set(installed.map { $0.source })
            snapshots.append(MappingSnapshot(registryID: id, original: current.filter { sources.contains($0.source) }, installed: installed))
            try saveJournal()
            try write(current.filter { !sources.contains($0.source) } + installed, to: service)
            log("系统映射写入并读回确认：\(installed.map { String(format: "%llX→%llX", $0.source, $0.destination) }.joined(separator: ", "))")
        }
        active = desired; activeIDs = ids
        return true
    }
    func invalidateConnection() { active = nil; activeIDs = [] }
    func restore() throws {
        if let loadError { throw failure(loadError) }
        let discovery = targets(allowUnbound: true)
        defer { withExtendedLifetime(discovery) {} }
        let devices = Dictionary(uniqueKeysWithValues: discovery.devices)
        var remaining: [MappingSnapshot] = []
        var firstError: Error?
        for snapshot in snapshots {
            guard let service = devices[snapshot.registryID] else { continue }
            do {
                let current = try read(service)
                let restored = snapshot.restoring(in: current)
                if current != restored { try write(restored, to: service) }
            } catch { remaining.append(snapshot); firstError = firstError ?? error }
        }
        snapshots = remaining; active = nil; activeIDs = []
        try saveJournal()
        if let firstError { throw firstError }
    }
}
