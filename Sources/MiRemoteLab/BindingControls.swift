import AppKit
import IOKit.hid

extension LabApp {
    @objc func bindRemote() { beginAddingRemote(replacing:nil) }
    @objc func repairListedDevice(_ sender: NSButton) {
        guard deviceLibrary.devices.indices.contains(sender.tag) else { return }
        beginAddingRemote(replacing:deviceLibrary.devices[sender.tag].id)
    }
    @objc func showRemoteCatalog() {
        let alert = NSAlert(); alert.messageText = "遥控器型号"
        alert.informativeText = "支持小米 2 Pro 和 Apple Siri Remote USB-C 第三代。一次使用当前选中的遥控器。"
        let chooser = NSPopUpButton(frame:NSRect(x:0,y:0,width:390,height:30),pullsDown:false)
        for model in RemoteModel.catalog { chooser.addItem(withTitle:model.title + (model.supported ? " · 支持" : " · 尚未支持")) }
        alert.accessoryView = chooser; alert.addButton(withTitle:"查看详情"); alert.addButton(withTitle:"关闭")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let model = RemoteModel.catalog[chooser.indexOfSelectedItem]
        if let design = AppleRemoteDesign.all.first(where:{ $0.model == model }) { showAppleDesign(design) }
        else {
            let details = NSAlert(); details.messageText = model.title
            details.informativeText = "银灰色 RC003 / RC003-MS。按键、短长按、连发、遥控器收音与电量读取已有单只实物验证。可保存多个设备，切换使用；一次只运行当前选中的一只。"
            details.runModal()
        }
    }
    func showAppleDesign(_ design: AppleRemoteDesign) {
        let alert = NSAlert(); alert.messageText = design.model.title + " · 适配规划"
        alert.informativeText = "\(design.modelNumbers) · \(design.identification)\n\n实体按键\n\(design.buttons.map(\.title).joined(separator:" · "))\n\n\(design.capabilitySummary)\n\n\(design.note)\nApple 官方兼容列表为 Apple TV；USB-C 第三代在遥伴中提供按键测试版，其他代尚未启用。"
        alert.addButton(withTitle:"知道了"); alert.addButton(withTitle:"苹果型号说明")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string:"https://support.apple.com/en-us/103233")!) }
    }
    func beginAddingRemote(replacing id: UUID?) {
        guard physicalKeys.isEmpty else { log("请先松开遥控器按键。"); return }
        recorder.cancel(); calibration.stop()
        if !isPreview { discovery.prepareDiscovery() }
        var model = id.flatMap { wanted in deviceLibrary.devices.first { $0.id == wanted }?.binding.model } ?? .xiaomi
        if id == nil {
            let alert = NSAlert(); alert.messageText = "选择遥控器型号"
            let picker = AddDeviceModelPicker()
            alert.accessoryView = picker.view
            alert.addButton(withTitle:"下一步"); alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            model = picker.model
        }
        let current = id.flatMap { wanted in deviceLibrary.devices.first { $0.id == wanted }?.binding } ?? .unbound(model:model)
        let picker = BluetoothBindingPicker(model:model,current:current) { [weak self] in
            self?.availableBindings(for:model,replacing:id) ?? []
        }
        picker.frame = NSRect(x:0,y:0,width:190,height:32)
        let alert = NSAlert(); alert.messageText = "选择蓝牙设备"
        alert.accessoryView = picker
        alert.addButton(withTitle:id == nil ? "添加" : "保存"); alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if saveRemoteBinding(picker.current,model:model,replacing:id), id == nil { showKeyPage() }
    }

    // Bluetooth and HID are separate interfaces on Xiaomi. Existing verified pairs
    // can be reused; a new pair is only offered when both remaining sides are unique.
    func availableBindings(for model: RemoteModel, replacing id: UUID?) -> [RemoteBinding] {
        if isPreview { return [] }
        let others = deviceLibrary.devices.filter { $0.id != id && $0.binding.isBound }
        let usedHID = Set(others.map { $0.binding.hidIdentity })
        let usedBLE = Set(others.compactMap { $0.binding.peripheralID })
        if model == .apple {
            return AppleHIDProbe.candidates().filter { !usedHID.contains($0.identity) }.compactMap {
                try? RemoteBinding(peripheralID:nil,hidIdentity:$0.identity,modelID:model.id,deviceName:$0.name).validated()
            }
        }
        guard model == .xiaomi else { return [] }
        let ble = discovery.connectedCandidates().filter { !usedBLE.contains($0.0) }
        let hid = mapper.availableIdentities().filter { !usedHID.contains($0) }
        if let existing = deviceLibrary.devices.first(where:{ $0.id == id })?.binding,
           existing.isBound, hid.contains(existing.hidIdentity), ble.contains(where:{ $0.0 == existing.peripheralID }) {
            return [existing]
        }
        guard ble.count == 1, hid.count == 1 else { return [] }
        let name = RemoteBluetoothDevice.displayName(ble[0].1) ?? model.name
        return (try? RemoteBinding(peripheralID:ble[0].0,hidIdentity:hid[0],modelID:model.id,deviceName:name).validated()).map { [$0] } ?? []
    }

    @discardableResult func saveRemoteBinding(_ proposed: RemoteBinding, model: RemoteModel, replacing id: UUID?) -> Bool {
        defer { lastDeviceListSignature = ""; refreshDeviceList() }
        guard physicalKeys.isEmpty, model.supported else { return false }
        do {
            let value = try proposed.validated()
            guard value.model == model else { throw PrivateFiles.error("设备型号不匹配。") }
            let existing = deviceLibrary.devices.first { $0.id == id }
            if id != nil && existing == nil { throw PrivateFiles.error("设备条目已删除。") }
            if let existing, existing.binding.model != model { throw PrivateFiles.error("设备型号不匹配。") }
            let unchanged = existing?.binding == value
            if value.isBound && !unchanged {
                guard !deviceLibrary.devices.contains(where:{ $0.id != id && $0.binding.isBound &&
                    ($0.binding.hidIdentity == value.hidIdentity || (value.peripheralID != nil && $0.binding.peripheralID == value.peripheralID)) }) else {
                    throw PrivateFiles.error("该蓝牙设备已绑定其他遥控器。")
                }
                guard availableBindings(for:model,replacing:id).contains(where:{ $0.hidIdentity == value.hidIdentity && $0.peripheralID == value.peripheralID }) else {
                    throw PrivateFiles.error("连接已变化，请重新选择蓝牙设备。")
                }
            }
            var next = deviceLibrary
            if let id, let index = next.devices.firstIndex(where:{ $0.id == id }) {
                next.devices[index].binding = value
                if let name = value.deviceName { next.devices[index].name = name }
            } else {
                let preferred = model == .apple ? BuiltInPreset.appleCodex.id : BuiltInPreset.codex.id
                guard let profile = library.profile(id:preferred,for:model.id) ?? library.profiles(for:model.id).first else {
                    throw PrivateFiles.error("没有可用的同型号预设。")
                }
                let baseName = value.deviceName ?? model.title
                var name = baseName, number = 2
                while next.devices.contains(where:{ $0.name == name }) { name = baseName + " \(number)"; number += 1 }
                let item = SavedRemote(name:name,binding:value,profileID:profile.id,
                    configuration:RemoteButtonLayout.configuration(profile.configuration,for:model))
                next.devices.append(item); next.selectDevice(item.id)
            }
            guard commitDevices(next) else { return false }
            lastDeviceListSignature = ""; refreshDeviceList(); makeStatusMenu()
            return true
        } catch {
            recordingLabel.stringValue = error.localizedDescription
            let alert = NSAlert(); alert.messageText = "绑定未保存"; alert.informativeText = error.localizedDescription
            if !isPreview { alert.runModal() }
            lastDeviceListSignature = ""; refreshDeviceList()
            return false
        }
    }
    @objc func clearRecordings() {
        guard !physicalKeys.contains(0x3E) else { log("请先松开麦克风键，再清理录音。"); return }
        let alert = NSAlert(); alert.messageText = "清理本应用保存的试听录音？"
        alert.informativeText = "删除当前应用诊断目录中的试听声音及其解码记录，按键设置和模式会保留。早期项目目录中的录音不在此次清理范围内。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清理录音")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try diagnostics?.removeRecordings(); latestRecording = nil; log("试听录音已清理。") }
        catch { log("清理失败：\(error.localizedDescription)") }
    }
}
