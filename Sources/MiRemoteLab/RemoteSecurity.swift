import Foundation

enum RemoteHIDIdentity {
    static func make(transport: String?, location: UInt64?) -> String? {
        guard transport == "Bluetooth Low Energy", let location, location > 0 else { return nil }
        return "ble:\(location)"
    }
}

struct RemoteBinding: Codable, Equatable {
    var version = 1
    let peripheralID: UUID?
    let hidIdentity: String
    var modelID: String? = nil
    var deviceName: String? = nil
    var model: RemoteModel { RemoteModel.catalog.first { $0.id == modelID } ?? .xiaomi }
    var isBound: Bool { !hidIdentity.isEmpty }
    static func unbound(model: RemoteModel) -> RemoteBinding {
        RemoteBinding(peripheralID:nil,hidIdentity:"",modelID:model.id)
    }
    func validated() throws -> RemoteBinding {
        let supportedModel = modelID.flatMap { id in RemoteModel.catalog.first { $0.id == id && $0.supported } }
        let validIdentity = modelID == RemoteModel.apple.id
            ? AppleRemoteIdentity.valid(hidIdentity) && peripheralID == nil
            : hidIdentity.hasPrefix("ble:") && UInt64(hidIdentity.dropFirst(4)).map({ $0 > 0 }) == true && peripheralID != nil
        let validUnbound = !isBound && peripheralID == nil && supportedModel != nil
        guard version == 1, validIdentity || validUnbound,
              modelID == nil || RemoteModel.catalog.contains(where: { $0.id == modelID && $0.supported }),
              deviceName.map({ !$0.isEmpty && $0.count <= 80 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) ?? true else {
            throw PrivateFiles.error("遥控器绑定记录无法识别，请重新绑定。")
        }
        return self
    }
}

// Audio can arrive slightly before the HID callback. Retain only the start
// request briefly, never audio, and consume each physical press at most once.
struct VoiceAuthorization {
    private(set) var held = false
    private(set) var consumed = false
    private var pendingAt: TimeInterval?
    mutating func press() -> Bool {
        guard !held else { return false }
        held = true; consumed = false
        return true
    }
    mutating func release() { held = false; consumed = false; pendingAt = nil }
    mutating func request(now: TimeInterval) -> Bool {
        guard !consumed else { return false }
        if held { consumed = true; pendingAt = nil; return true }
        pendingAt = now
        return false
    }
    mutating func acceptPending(now: TimeInterval) -> Bool {
        guard held, !consumed, let since = pendingAt, now >= since, now - since <= 0.3 else {
            pendingAt = nil; return false
        }
        consumed = true; pendingAt = nil; return true
    }
    mutating func reset() { self = VoiceAuthorization() }
}
