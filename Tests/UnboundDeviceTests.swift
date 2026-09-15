import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

func requireRejected(_ message: String, _ body: () throws -> Void) {
    do {
        try body()
        fatalError(message)
    } catch {}
}

@main struct UnboundDeviceTests {
    static func main() throws {
        let xiaomiUnbound = RemoteBinding.unbound(model:.xiaomi)
        let appleUnbound = RemoteBinding.unbound(model:.apple)
        require(!xiaomiUnbound.isBound && xiaomiUnbound.peripheralID == nil && xiaomiUnbound.hidIdentity.isEmpty,
                "unbound factory must omit both device identities")
        require(xiaomiUnbound.modelID == RemoteModel.xiaomi.id && appleUnbound.modelID == RemoteModel.apple.id,
                "unbound factory must retain the explicitly selected supported model")
        _ = try xiaomiUnbound.validated()
        _ = try appleUnbound.validated()

        requireRejected("an unbound binding without an explicit model must fail") {
            _ = try RemoteBinding(peripheralID:nil,hidIdentity:"").validated()
        }
        requireRejected("an empty HID identity with a peripheral must fail") {
            _ = try RemoteBinding(peripheralID:UUID(),hidIdentity:"",modelID:RemoteModel.xiaomi.id).validated()
        }
        requireRejected("an unsupported model cannot be saved unbound") {
            _ = try RemoteBinding.unbound(model:.appleSecond).validated()
        }
        requireRejected("a non-empty Xiaomi identity still requires a peripheral") {
            _ = try RemoteBinding(peripheralID:nil,hidIdentity:"ble:41",modelID:RemoteModel.xiaomi.id).validated()
        }

        let xiaomiConfiguration = BuiltInPreset.codex.configuration
        let appleConfiguration = BuiltInPreset.appleCodex.configuration
        let first = SavedRemote(name:"稍后绑定的小米",binding:xiaomiUnbound,
                                profileID:BuiltInPreset.codex.id,configuration:xiaomiConfiguration)
        let second = SavedRemote(name:"另一台稍后绑定的小米",binding:xiaomiUnbound,
                                 profileID:BuiltInPreset.codex.id,configuration:xiaomiConfiguration)
        let apple = SavedRemote(name:"稍后绑定的 Apple",binding:appleUnbound,
                                profileID:BuiltInPreset.appleCodex.id,configuration:appleConfiguration)
        var unboundLibrary = RemoteDeviceLibrary(selectedID:second.id,devices:[first,second,apple])
        _ = try unboundLibrary.validated()
        require(unboundLibrary.selected?.id == second.id && unboundLibrary.activeID == nil,
                "an unbound device remains selected for editing but cannot become active")

        let bound = SavedRemote(name:"已绑定的小米",
                                binding:RemoteBinding(peripheralID:UUID(),hidIdentity:"ble:4101",modelID:RemoteModel.xiaomi.id),
                                profileID:BuiltInPreset.codex.id,configuration:xiaomiConfiguration)
        unboundLibrary.devices.append(bound)
        unboundLibrary.selectDevice(bound.id)
        require(unboundLibrary.activeID == bound.id,
                "selecting a valid bound device activates it")
        unboundLibrary.selectDevice(apple.id)
        require(unboundLibrary.selected?.id == apple.id && unboundLibrary.activeID == nil,
                "selecting an unbound device changes the editor selection without starting a receiver")
        require(unboundLibrary.devices.first(where:{ $0.id == bound.id })?.enabled == false,
                "selecting an unbound device stops the previously active device")

        let duplicateHID = SavedRemote(name:"重复 HID",
                                      binding:RemoteBinding(peripheralID:UUID(),hidIdentity:bound.binding.hidIdentity,modelID:RemoteModel.xiaomi.id),
                                      profileID:BuiltInPreset.codex.id,configuration:xiaomiConfiguration)
        var duplicateLibrary = RemoteDeviceLibrary(selectedID:bound.id,devices:[bound,duplicateHID])
        requireRejected("two bound devices cannot share one HID identity") { _ = try duplicateLibrary.validated() }

        let duplicatePeripheral = SavedRemote(name:"重复蓝牙",
                                             binding:RemoteBinding(peripheralID:bound.binding.peripheralID,hidIdentity:"ble:4102",modelID:RemoteModel.xiaomi.id),
                                             profileID:BuiltInPreset.codex.id,configuration:xiaomiConfiguration)
        duplicateLibrary = RemoteDeviceLibrary(selectedID:bound.id,devices:[bound,duplicatePeripheral])
        requireRejected("two bound devices cannot share one peripheral identity") { _ = try duplicateLibrary.validated() }

        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("yaoban-unbound-device-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let store = RemoteDeviceStore(directory:root)
        try store.save(unboundLibrary)
        let profiles = MappingLibrary(selectedID:BuiltInPreset.codex.id,profiles:[
            .init(id:BuiltInPreset.codex.id,name:"Codex",modelID:RemoteModel.xiaomi.id,configuration:xiaomiConfiguration),
            .init(id:BuiltInPreset.appleCodex.id,name:"Codex",modelID:RemoteModel.apple.id,configuration:appleConfiguration)
        ])
        let reloaded = try store.load(migrating:root.appendingPathComponent("不存在的旧绑定.json"),profiles:profiles)
        require(reloaded.version == 4 && reloaded == unboundLibrary,
                "schema v4 must round-trip unbound state, selection, profiles and mapping snapshots exactly")

        print("PASS: unbound model persistence, strict partial-state validation, bound duplicate rejection and inactive editor selection")
    }
}
