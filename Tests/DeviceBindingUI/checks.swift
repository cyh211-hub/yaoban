let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let lab = LabApp()
precondition(lab.isPreview)
lab.store = MappingStore(directory:URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("yaoban-binding-ui-"+UUID().uuidString))
lab.deviceStore = RemoteDeviceStore(directory:lab.store.directory)
try lab.library.installBuiltInsIfNeeded()
lab.makeWindow(); lab.storageReady = true
try lab.store.saveLibrary(lab.library); try lab.deviceStore.save(lab.deviceLibrary)
lab.loadDeviceEditor()
func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let destination = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("docs/v0.10.5/previews")
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
func export(_ view:NSView,_ name:String) throws {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { fatalError("bitmap") }
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(name))
}
lab.window.appearance = NSAppearance(named:.aqua)

// A fresh install has no phantom key rows or editable mapping surface.
lab.selectPage(0); lab.window.contentView!.layoutSubtreeIfNeeded()
let mappingControls = lab.settingsSubview(withIdentifier:.init("keyMappingControls"),in:lab.pageHost)!
let mappingEmptyState = lab.settingsSubview(withIdentifier:.init("keyMappingEmptyState"),in:lab.pageHost)!
precondition(lab.rows.isEmpty && lab.numberOfRows(in:lab.table) == 0)
precondition(mappingControls.isHidden && !mappingEmptyState.isHidden)
try export(lab.window.contentView!,"keys-empty.png")
lab.selectPage(4); lab.window.contentView!.layoutSubtreeIfNeeded()
let emptyDeviceButtons = descendants(lab.pages[4]).compactMap { $0 as? NSButton }
let emptyDeviceText = descendants(lab.pages[4]).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator:" ")
precondition(emptyDeviceText.contains("还没有遥控器"))
precondition(!emptyDeviceButtons.contains { ["正在使用","使用此设备"].contains($0.title) })
try export(lab.window.contentView!,"devices-empty.png")

let picker = AddDeviceModelPicker()
precondition(picker.models == [.xiaomi,.apple] && picker.view.arrangedSubviews.count == 1)
picker.chooser.selectItem(at:1)
precondition(picker.model == .apple)
for model in [RemoteModel.apple,.apple,.xiaomi] {
    precondition(lab.saveRemoteBinding(.unbound(model:model),model:model,replacing:nil))
    precondition(lab.selectedDevice?.binding.model == model && lab.deviceLibrary.activeID == nil)
    precondition(lab.lastDeviceStatus?.connection == .unbound)
    precondition(lab.profilePopup.itemArray.compactMap { $0.representedObject as? String } == lab.library.profiles(for:model.id).map(\.id))
    precondition(lab.testMenu.items.first!.title.hasSuffix("未绑定设备"))
}
let first = lab.deviceLibrary.devices[0]
let second = lab.deviceLibrary.devices[1]
let xiaomi = lab.deviceLibrary.devices[2]
let physical = RemoteBinding(peripheralID:nil,hidIdentity:"apple3loc:9001",modelID:RemoteModel.apple.id,deviceName:"我的 Siri Remote")
lab.testCandidates = [physical]
let original = first.configuration
precondition(lab.saveRemoteBinding(physical,model:.apple,replacing:first.id))
let bound = lab.deviceLibrary.devices.first { $0.id == first.id }!
precondition(bound.configuration == original && bound.profileID == first.profileID && bound.startupProfileID == first.startupProfileID)
precondition(lab.deviceLibrary.selectedID == xiaomi.id) // Binding another row must not switch active device.
let beforeDuplicate = lab.deviceLibrary
precondition(!lab.saveRemoteBinding(physical,model:.apple,replacing:second.id))
precondition(lab.deviceLibrary == beforeDuplicate)
lab.testCandidates = []
let vanished = RemoteBinding(peripheralID:nil,hidIdentity:"apple3loc:9002",modelID:RemoteModel.apple.id)
precondition(!lab.saveRemoteBinding(vanished,model:.apple,replacing:second.id))
precondition(!lab.saveRemoteBinding(physical,model:.xiaomi,replacing:xiaomi.id))
precondition(lab.deviceLibrary == beforeDuplicate)
// An offline current binding is still selectable; clearing it affects neither mappings nor presets.
let offlinePicker = BluetoothBindingPicker(model:.apple,current:physical,candidates:{ [] })
precondition(offlinePicker.numberOfItems == 2 && offlinePicker.indexOfSelectedItem == 1)
precondition((offlinePicker.selectedItem?.representedObject as? RemoteBinding) == physical)
precondition(lab.saveRemoteBinding(.unbound(model:.apple),model:.apple,replacing:first.id))
precondition(lab.deviceLibrary.devices[0].configuration == original && lab.deviceLibrary.devices[0].startupProfileID == first.startupProfileID)
lab.testCandidates = [physical]
precondition(lab.saveRemoteBinding(physical,model:.apple,replacing:second.id))
let choice = NSMenuItem(title:"test",action:nil,keyEquivalent:""); choice.representedObject = second.id.uuidString
lab.menuDeviceSelected(choice)
precondition(lab.deviceLibrary.activeID == second.id)
precondition(Set(lab.editingDevicePopup.itemTitles).count == lab.deviceLibrary.devices.count)
precondition(Set(lab.testMenu.items.first!.submenu!.items.map(\.title)).count == lab.deviceLibrary.devices.count)
let expected = lab.library.profiles(for:RemoteModel.apple.id)
precondition(lab.profilePopup.itemTitles == expected.map(\.displayName))
precondition(lab.testMenu.items.first { $0.title == "加载预设" }!.submenu!.items.map(\.title) == expected.map(\.displayName))
precondition(!lab.profilePopup.itemTitles.contains { $0.contains("★") || $0.contains(" · Apple") || $0.contains(" · 小米") })
let all = descendants(lab.window.contentView!)
let forbidden = Set(["管理设备","设备详情","查看键位","切换使用"])
precondition(!all.compactMap { ($0 as? NSButton)?.title }.contains { forbidden.contains($0) })
precondition(!all.contains { $0 === lab.repeatToggle })
precondition(!all.compactMap { ($0 as? NSButton)?.title }.contains { $0.contains("启用当前模式的长按连发") })
precondition(lab.deviceList.arrangedSubviews.count == 3)
precondition(descendants(lab.deviceList).filter { $0 is BluetoothBindingPicker }.count == 3)
let deviceButtons = descendants(lab.pages[4]).compactMap { $0 as? NSButton }
precondition(!deviceButtons.contains { ["正在使用","使用此设备"].contains($0.title) })

// Per-key repeat remains available even though the old global checkbox is gone.
let triggerColumn = lab.table.tableColumn(withIdentifier:.init("trigger"))!
let triggerCell = lab.tableView(lab.table,viewFor:triggerColumn,row:0)!
let triggerPopup = descendants(triggerCell).compactMap { $0 as? NSPopUpButton }.first!
precondition(triggerPopup.itemArray.compactMap { $0.representedObject as? String }.contains(ActionTrigger.repeating.rawValue))

// An empty key binding has exactly one disabled choice and still offers creation.
let emptySource = lab.rows[0]
precondition(lab.editDeviceConfiguration { $0.bindings[emptySource] = [] })
let bindingColumn = lab.table.tableColumn(withIdentifier:.init("binding"))!
let bindingCell = lab.tableView(lab.table,viewFor:bindingColumn,row:0)!
let bindingPopup = descendants(bindingCell).compactMap { $0 as? NSPopUpButton }.first!
precondition(bindingPopup.itemTitles.filter { $0 == "无映射" }.count == 1)
precondition(bindingPopup.itemArray.filter { ($0.representedObject as? String) == "none" }.count == 1)
precondition(bindingPopup.itemArray.filter { ($0.representedObject as? String) == "create" }.count == 1)

// Gesture edits auto-save only this device; saving the preset is explicit and
// survives a different-preset round trip plus a disk reload.
let gestureDevice = lab.selectedDevice!
let gestureProfileID = gestureDevice.profileID
let otherTouches = Dictionary(uniqueKeysWithValues:lab.deviceLibrary.devices.filter { $0.id != gestureDevice.id }.map { ($0.id,$0.configuration.touch) })
let profileTouchBefore = lab.library.profile(id:gestureProfileID,for:RemoteModel.apple.id)!.configuration.touch
var gestureTouch = lab.configuration.touch
gestureTouch.mode = .hybrid; gestureTouch.speed = 1.8; gestureTouch.acceleration = false
gestureTouch.tapInterval = 0.4; gestureTouch.ringStartRadius = 0.4; gestureTouch.swipeDistance = 0.22
let gestureKeys: [RemoteTouchGesture:[UInt16]] = [
    .tap1:[0xE0,0x28], .tap2:[0xE1,0x04], .tap3:[0xE2,0x05],
    .swipeUp:[0x52], .swipeDown:[0x51], .swipeLeft:[0x50], .swipeRight:[0x4F]
]
for (gesture,keys) in gestureKeys { gestureTouch.setBinding(keys,for:gesture) }
precondition(lab.editDeviceConfiguration { $0.touch = gestureTouch })
precondition(lab.configuration.touch == gestureTouch)
precondition(otherTouches.allSatisfy { id,touch in lab.deviceLibrary.devices.first { $0.id == id }!.configuration.touch == touch })
precondition(lab.library.profile(id:gestureProfileID,for:RemoteModel.apple.id)!.configuration.touch == profileTouchBefore)

lab.refreshTouchControls()
precondition(lab.touchGesturePopups.count == 7 && Set(lab.touchGesturePopups.keys) == Set(RemoteTouchGesture.allCases))
let labelTokens: [RemoteTouchGesture:[String]] = [
    .tap1:["轻点","一次"], .tap2:["轻点","两次"], .tap3:["轻点","三次"],
    .swipeUp:["上","滑动"], .swipeDown:["下","滑动"], .swipeLeft:["左","滑动"], .swipeRight:["右","滑动"]
]
for gesture in RemoteTouchGesture.allCases {
    let popup = lab.touchGesturePopups[gesture]!
    let choices = popup.itemArray.compactMap { $0.representedObject as? String }
    precondition(choices.filter { $0 == "none" }.count == 1 && choices.filter { $0 == "create" }.count == 1)
    let accessible = popup.accessibilityLabel() ?? ""
    precondition(!accessible.isEmpty && labelTokens[gesture]!.allSatisfy(accessible.contains))
}
let sliderBounds: [(String,Double,Double)] = [
    ("touchTapInterval",0.2,0.6), ("touchRingRadius",0.2,0.45), ("touchSwipeDistance",0.1,0.5)
]
for (identifier,minimum,maximum) in sliderBounds {
    let slider = lab.settingsSubview(withIdentifier:.init(identifier),in:lab.pages[5]) as! NSSlider
    precondition(slider.minValue == minimum && slider.maxValue == maximum)
}

lab.saveCurrentProfile()
precondition(lab.library.profile(id:gestureProfileID,for:RemoteModel.apple.id)!.configuration.touch == gestureTouch)
precondition(otherTouches.allSatisfy { id,touch in lab.deviceLibrary.devices.first { $0.id == id }!.configuration.touch == touch })
let alternateGestureProfile = lab.library.profiles(for:RemoteModel.apple.id).first { $0.id != gestureProfileID }!
lab.loadProfile(alternateGestureProfile.id)
precondition(lab.configuration.touch != gestureTouch)
lab.loadProfile(gestureProfileID)
precondition(lab.configuration.touch == gestureTouch)
precondition(lab.reloadSavedMappings() && lab.configuration.touch == gestureTouch)

// The complete gesture surface scrolls at the declared minimum window size.
lab.window.setContentSize(NSSize(width:1040,height:740)); lab.selectPage(5)
lab.window.contentView!.layoutSubtreeIfNeeded()
let touchScrolls = descendants(lab.pages[5]).compactMap { $0 as? NSScrollView }
precondition(touchScrolls.contains { $0.hasVerticalScroller && $0.documentView != nil })
let touchScroll = touchScrolls.first { $0.hasVerticalScroller && $0.documentView != nil }!
precondition(touchScroll.documentView!.fittingSize.height > touchScroll.contentView.bounds.height)
try export(lab.window.contentView!,"apple-touch-minimum.png")
lab.window.setContentSize(NSSize(width:1120,height:860))

lab.window.setContentSize(NSSize(width:1120,height:860)); lab.selectPage(4)
lab.window.contentView!.layoutSubtreeIfNeeded()
let remoteFrame = lab.editingDevicePopup.convert(lab.editingDevicePopup.bounds,to:lab.window.contentView!)
let presetFrame = lab.profilePopup.convert(lab.profilePopup.bounds,to:lab.window.contentView!)
precondition(abs(remoteFrame.midY - presetFrame.midY) < 2 && remoteFrame.maxX < presetFrame.minX)
for view in [lab.editingDevicePopup,lab.profilePopup,lab.loadProfileButton,lab.saveProfileButton,lab.modeMoreButton] as [NSView] {
    let rect = view.convert(view.bounds,to:lab.window.contentView!)
    precondition(rect.width > 0 && rect.minX >= 0 && rect.maxX <= lab.window.contentView!.bounds.width)
}
let reloaded = try lab.deviceStore.load(migrating:lab.store.directory.appendingPathComponent("absent.json"),profiles:lab.library)
precondition(reloaded == lab.deviceLibrary)
// Exercise the real commit path with a deterministic write failure and stubbed
// hardware start/stop. No HID, Bluetooth connection or output event is started.
let oldState = lab.deviceLibrary
let oldBytes = try Data(contentsOf:lab.deviceStore.directory.appendingPathComponent("设备库.json"))
let fakeRuntime = RemoteRuntime(record:lab.selectedDevice!,directory:lab.store.directory,emitter:lab.emitter,outputOwners:lab.outputOwners,voiceOwners:lab.voiceOwners,systemMic:lab.systemMic)
fakeRuntime.selectedForInput = true; fakeRuntime.start()
lab.runtimes[fakeRuntime.id] = fakeRuntime
lab.testFailDeviceSave = true
var nextSelection = oldState; nextSelection.selectDevice(xiaomi.id)
precondition(!lab.commitDevices(nextSelection))
precondition(fakeRuntime.testStops == 1 && fakeRuntime.testStarts == 2 && fakeRuntime.running)
precondition(lab.runtimes.values.filter(\.running).count == 1)
precondition(lab.deviceLibrary == oldState && (try! Data(contentsOf:lab.deviceStore.directory.appendingPathComponent("设备库.json"))) == oldBytes)
fakeRuntime.testRestoreFailure = true
precondition(!lab.commitDevices(nextSelection))
precondition(fakeRuntime.testStops == 2 && fakeRuntime.testStarts == 2 && !fakeRuntime.running)
precondition(lab.deviceLibrary == oldState && (try! Data(contentsOf:lab.deviceStore.directory.appendingPathComponent("设备库.json"))) == oldBytes)
lab.testFailDeviceSave = false; fakeRuntime.testRestoreFailure = false; fakeRuntime.stop(); lab.runtimes.removeAll()
precondition(lab.runtimes.isEmpty && !lab.emitter.isObserving && !lab.recorder.isActive)
try export(lab.window.contentView!,"devices-isolated.png")
lab.recordingLabel.stringValue = "选择映射以修改按键。"
lab.selectPage(0); try export(lab.window.contentView!,"keys-isolated.png")
let alert = NSAlert(); alert.messageText = "选择遥控器型号"; alert.accessoryView = picker.view
alert.addButton(withTitle:"下一步"); alert.addButton(withTitle:"取消"); alert.layout()
precondition(descendants(alert.window.contentView!).filter { $0 is NSPopUpButton }.count == 1)
alert.accessoryView = nil
try FileManager.default.removeItem(at:lab.store.directory)
print("PASS: v0.10.5 native empty state, no device/global repeat switches, per-key repeat and unambiguous mapping creation; seven isolated gesture mappings and thresholds persist through preset and disk reload; minimum touch page scrolls; injected save/restore failures remain safe; no live input or UI shown")
