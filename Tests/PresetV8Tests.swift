import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

@main struct PresetV8Tests {
static func main() throws {
let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("yaoban-preset-v8-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at:root) }
let store = MappingStore(directory:root)
let deviceStore = RemoteDeviceStore(directory:root)

let clean = try store.loadForApp().library
require(clean.unassignedProfiles.isEmpty,"clean install must not create a placeholder profile")
require(clean.profiles(for:RemoteModel.xiaomi.id).count == 2,"clean Xiaomi presets are isolated")
require(clean.profiles(for:RemoteModel.apple.id).count == 2,"clean Apple presets are isolated")
require(clean.profile(id:BuiltInPreset.appleCodex.id,for:RemoteModel.apple.id)?.configuration.touch.mode == .hybrid,"new Apple Codex defaults to hybrid touch")
require(clean.profile(id:BuiltInPreset.codex.id,for:RemoteModel.xiaomi.id)?.configuration.touch.mode == .off,"Apple touch default must not affect Xiaomi")
require(clean.profile(id:BuiltInPreset.appleCodex.id,for:RemoteModel.xiaomi.id) == nil,"cross-model lookup must fail")

// Build a v7 document with one custom profile used by two models and one
// unreferenced profile. The coordinated migration must retain both originals and
// produce separate owned copies for the devices.
var sourceConfiguration = BuiltInPreset.codex.configuration
sourceConfiguration.bindings[0x28] = [0xE3,0x28]
let legacy = MappingLibrary(selectedID:"legacy.shared",profiles:[
    .init(id:"legacy.shared",name:"我的自定义",configuration:sourceConfiguration),
    .init(id:"legacy.orphan",name:"默认预设",configuration:sourceConfiguration)
])
try store.saveLibrary(legacy)
var presetJSON = try JSONSerialization.jsonObject(with:PrivateFiles.read(store.url)) as! [String:Any]
presetJSON["version"] = 7
presetJSON["profiles"] = (presetJSON["profiles"] as! [[String:Any]]).map { row in var next=row; next.removeValue(forKey:"modelID"); return next }
try PrivateFiles.write(JSONSerialization.data(withJSONObject:presetJSON),to:store.url)

let xBinding = RemoteBinding(peripheralID:UUID(),hidIdentity:"ble:401",modelID:RemoteModel.xiaomi.id)
let aBinding = RemoteBinding(peripheralID:nil,hidIdentity:"apple3loc:9401",modelID:RemoteModel.apple.id)
let xConfig = RemoteButtonLayout.configuration(sourceConfiguration,for:.xiaomi)
var aConfig = RemoteButtonLayout.configuration(sourceConfiguration,for:.apple); aConfig.touch.mode = .off
let x = SavedRemote(name:"旧小米",binding:xBinding,profileID:"legacy.shared",configuration:xConfig)
let a = SavedRemote(name:"旧 Apple",binding:aBinding,profileID:"legacy.shared",configuration:aConfig)
let oldDevices = RemoteDeviceLibrary(version:2,selectedID:x.id,devices:[x,a])
try deviceStore.save(oldDevices)
var deviceJSON = try JSONSerialization.jsonObject(with:PrivateFiles.read(deviceStore.url)) as! [String:Any]
deviceJSON["version"] = 2
deviceJSON["devices"] = (deviceJSON["devices"] as! [[String:Any]]).map { row in var next=row; next.removeValue(forKey:"startupProfileID"); return next }
try PrivateFiles.write(JSONSerialization.data(withJSONObject:deviceJSON),to:deviceStore.url)

let originalV7 = try PrivateFiles.read(store.url)
let loadedProfiles = try store.loadForApp().library
let loadedDevices = try deviceStore.load(migrating:root.appendingPathComponent("遥控器绑定.json"),profiles:loadedProfiles)
let prepared = try DevicePresetTransaction.prepareForLaunch(profiles:loadedProfiles,devices:loadedDevices,store:store,deviceStore:deviceStore)
let archivedV7 = try PrivateFiles.read(store.modelMigrationBackupURL)
require(archivedV7 == originalV7,"v7 bytes survive coordinated migration and rolling saves")
require(prepared.profiles.unassignedProfiles.contains(where:{ $0.id == "legacy.shared" && $0.configuration == sourceConfiguration }),"referenced legacy source must remain losslessly retained")
require(prepared.profiles.unassignedProfiles.contains(where:{ $0.id == "legacy.orphan" }),"unattributable legacy profile must remain retained")
require(prepared.profiles.profiles(for:RemoteModel.xiaomi.id).allSatisfy { !["默认","默认预设","我的自定义"].contains($0.name) },"obsolete placeholder names must not return in the device picker")
let migratedX = prepared.devices.devices.first { $0.id == x.id }!
let migratedA = prepared.devices.devices.first { $0.id == a.id }!
require(migratedX.profileID != migratedA.profileID,"shared legacy profile must split by model")
require(prepared.profiles.profile(id:migratedX.profileID,for:RemoteModel.xiaomi.id) != nil,"Xiaomi copy has Xiaomi ownership")
require(prepared.profiles.profile(id:migratedA.profileID,for:RemoteModel.apple.id) != nil,"Apple copy has Apple ownership")
require(migratedX.configuration == xConfig && migratedA.configuration == aConfig,"device snapshots survive migration exactly")
require(migratedX.startupProfileID == migratedX.profileID && migratedA.startupProfileID == migratedA.profileID,"old devices receive real startup references")

let countAfterMigration = prepared.profiles.profiles.count
var editedDevices = prepared.devices
editedDevices.devices[0].configuration.bindings[0x28] = [0x2C]
editedDevices.devices[1].configuration.bindings[0x28] = [0x29]
let restarted = try DevicePresetTransaction.prepareForLaunch(profiles:prepared.profiles,devices:editedDevices,store:store,deviceStore:deviceStore)
require(restarted.profiles.profiles.count == countAfterMigration,"v8 migration is idempotent")
require(restarted.devices.devices[0].configuration == prepared.profiles.profile(id:migratedX.startupProfileID!,for:RemoteModel.xiaomi.id)!.configuration,"startup loads the referenced preset")
require(restarted.devices.devices[1].configuration.bindings[0x28] == [0x29],"inactive device keeps its remembered working snapshot")

var deleteProfiles = restarted.profiles
let startupID = restarted.devices.devices[0].startupProfileID!
let alternativeID = UUID().uuidString
var alternative = xConfig; alternative.bindings[0x28] = [0x29]
deleteProfiles.profiles.append(.init(id:alternativeID,name:"临时预设",modelID:RemoteModel.xiaomi.id,configuration:alternative))
var deleteDevices = restarted.devices
deleteDevices.devices[0].profileID = alternativeID; deleteDevices.devices[0].configuration = alternative
try deleteProfiles.delete(alternativeID)
deleteDevices.reconcileProfiles(deleteProfiles,removedProfileIDs:[alternativeID])
require(deleteDevices.devices[0].profileID == startupID,"deleting current preset returns to startup reference")
require(deleteDevices.devices[0].configuration == deleteProfiles.profile(id:startupID,for:RemoteModel.xiaomi.id)!.configuration,"deleting current preset loads startup contents")

// Restoring a retained device snapshot materializes an owned preset and commits
// both records together, so the next startup cannot replace it with a fallback.
var restoredProfiles = restarted.profiles, restoredDevices = restarted.devices
let restoredID = UUID().uuidString
restoredProfiles.profiles.append(.init(id:restoredID,name:"恢复的 Apple 键位",modelID:RemoteModel.apple.id,configuration:aConfig))
restoredProfiles.selectedID = restoredID
let restoredBinding = RemoteBinding(peripheralID:nil,hidIdentity:"apple3loc:9501",modelID:RemoteModel.apple.id)
let restoredRemote = SavedRemote(name:"恢复 Apple",binding:restoredBinding,profileID:restoredID,configuration:aConfig)
restoredDevices.devices.append(restoredRemote)
try DevicePresetTransaction.commit(profiles:restoredProfiles,devices:restoredDevices,store:store,deviceStore:deviceStore)
let restoredOnDisk = try deviceStore.load(migrating:root.appendingPathComponent("遥控器绑定.json"),profiles:restoredProfiles)
require(restoredOnDisk.devices.first(where:{ $0.id == restoredRemote.id })?.startupProfileID == restoredID,"retained restore persists the new owned startup preset atomically")
let restoredLibrary = try store.load().library
require(restoredLibrary.profile(id:restoredID,for:RemoteModel.apple.id)?.configuration == aConfig,"retained restore persists exact profile configuration")

let beforeDraftProfiles = try PrivateFiles.read(store.url)
let beforeDraftDevices = try PrivateFiles.read(deviceStore.url)
var draft = PresetDraftSession(deviceID:migratedA.id,profileID:migratedA.profileID,configuration:migratedA.configuration,model:.apple)
draft.configuration.bindings[0x28] = [0x28]
require(RemoteButtonLayout.appleRows.allSatisfy { draft.configuration.bindings[$0] != nil },"clear draft explicitly disables every Apple button")
require(draft.configuration.longBindings.isEmpty && draft.configuration.touch.mode == .off,"clear draft removes long press and touch actions")
let afterDraftProfiles = try PrivateFiles.read(store.url), afterDraftDevices = try PrivateFiles.read(deviceStore.url)
require(afterDraftProfiles == beforeDraftProfiles && afterDraftDevices == beforeDraftDevices,"draft editing must not write either saved file")

let oldAppleProfile = MappingProfile(id:"builtin.appleCodex.v1",name:"Codex · Apple",modelID:RemoteModel.apple.id,configuration:aConfig)
let newAppleProfile = MappingProfile(id:BuiltInPreset.appleCodex.id,name:"Codex",modelID:RemoteModel.apple.id,configuration:aConfig)
let xiaomiProfile = MappingProfile(id:BuiltInPreset.codex.id,name:"Codex",modelID:RemoteModel.xiaomi.id,configuration:xConfig)
let mixedMenuLibrary = MappingLibrary(selectedID:newAppleProfile.id,profiles:[oldAppleProfile,newAppleProfile,xiaomiProfile])
require(mixedMenuLibrary.profiles(for:RemoteModel.apple.id).map(\.displayName) == ["Codex（旧版）","Codex"],"Apple scoped choices omit redundant brand labels")
require(mixedMenuLibrary.profiles(for:RemoteModel.xiaomi.id).map(\.displayName) == ["Codex"],"same-name Xiaomi choice remains independently scoped")
require(oldAppleProfile.name == "Codex · Apple" && oldAppleProfile.configuration == aConfig,"presentation preserves edited legacy preset data")

print("PASS: v8 model isolation, lossless split migration, startup loading, deletion fallback, non-persistent clear draft and device-qualified preset menus")
}
}
