import AppKit

extension LabApp {
    var visibleProfiles: [MappingProfile] {
        guard let modelID = selectedDevice?.binding.model.id else { return [] }
        return library.profiles(for:modelID)
    }
    var hasUnsavedPresetDraft: Bool { presetDraft != nil }

    func refreshProfileControls() {
        profilePopup.removeAllItems()
        for profile in visibleProfiles {
            profilePopup.addItem(withTitle:profile.displayName); profilePopup.lastItem?.representedObject = profile.id
        }
        if visibleProfiles.isEmpty { profilePopup.addItem(withTitle:"请先选择遥控器") }
        profilePopup.isEnabled = !visibleProfiles.isEmpty && presetDraft == nil
        modeMoreButton.itemArray.first(where:{ $0.action == #selector(clearCurrentPreset) })?.isEnabled = selectedDevice != nil && presetDraft == nil
        modeMoreButton.itemArray.first(where:{ $0.action == #selector(discardCurrentPreset) })?.isEnabled = presetDraft != nil
        refreshProfileSelection(); repeatToggle.state = configuration.repeatEnabled ? .on : .off
        refreshLongDelayControl(); makeStatusMenu()
    }
    func refreshProfileSelection() {
        guard let selected = visibleProfiles.first(where:{ $0.id == pendingProfileID }) ?? visibleProfiles.first(where:{ $0.id == selectedDevice?.profileID }) ?? visibleProfiles.first else {
            pendingProfileID = nil; loadProfileButton.isEnabled = false; saveProfileButton.isEnabled = false
            deleteProfileButton.isEnabled = false; currentModeLabel.stringValue = "预设："
            profileSelectionLabel.stringValue = library.unassignedProfiles.isEmpty ? "添加遥控器后可选择预设" : "旧预设已安全保留，选择遥控器后再归属"
            return
        }
        pendingProfileID = selected.id
        profilePopup.selectItem(at:visibleProfiles.firstIndex { $0.id == selected.id }!)
        let loaded = selected.id == selectedDevice?.profileID
        let template = selectedDevice.map { RemoteButtonLayout.configuration(selected.configuration,for:$0.binding.model) } ?? selected.configuration
        let changed = configuration != template
        loadProfileButton.isEnabled = presetDraft == nil && (!loaded || changed)
        saveProfileButton.isEnabled = loaded || presetDraft != nil
        saveProfileButton.alphaValue = loaded ? 1 : 0.45
        saveProfileButton.toolTip = "将当前设备的完整键位保存为此预设；其他设备保持自己的当前键位，重新加载后采用新预设。"
        let startup = deviceLibrary.devices.contains { $0.startupProfileID == selected.id }
        deleteProfileButton.isEnabled = !startup && visibleProfiles.count > 1
        currentModeLabel.stringValue = "预设："
        modeMoreButton.itemArray.first(where:{ $0.action == #selector(deleteProfile) })?.isEnabled = !startup && visibleProfiles.count > 1
        profileSelectionLabel.stringValue = selectedDevice == nil ? "添加遥控器后可选择预设"
            : presetDraft != nil ? "未保存修改"
            : !loaded ? "待加载：\(selected.name)" : changed ? "当前键位已记忆 · 预设未更新" : ""
        profileSelectionLabel.textColor = changed ? Self.accent : .secondaryLabelColor
    }
    @discardableResult func editProfiles(removedProfileIDs: Set<String> = [], _ operation: (inout MappingLibrary) throws -> Void) -> Bool {
        guard storageReady else { recordingLabel.stringValue = "设置尚未恢复，请先重新检测。"; return false }
        guard physicalKeys.isEmpty else { recordingLabel.stringValue = "请先松开遥控器按键。"; return false }
        recorder.cancel(); calibration.stop()
        do {
            var updated = library
            try operation(&updated); _ = try updated.validated()
            var devices = deviceLibrary; devices.reconcileProfiles(updated,removedProfileIDs:removedProfileIDs)
            try DevicePresetTransaction.commit(profiles:updated,devices:devices,store:store,deviceStore:deviceStore)
            library = updated; deviceLibrary = devices; rebuildRuntimes(); loadDeviceEditor()
            recordingLabel.stringValue = "预设已保存 · 各设备的当前键位独立保留"
            return true
        } catch {
            recordingLabel.stringValue = "保存未完成：" + error.localizedDescription; log(recordingLabel.stringValue)
            if FileManager.default.fileExists(atPath:DevicePresetTransaction.url(store).path) { stopTest() }
            refreshProfileControls(); return false
        }
    }
    @objc func saveCurrentProfile() {
        guard storageReady, physicalKeys.isEmpty else { recordingLabel.stringValue = "请先松开遥控器按键并完成设置恢复。"; return }
        guard let device = selectedDevice, pendingProfileID == device.profileID, !recorder.isActive else { recordingLabel.stringValue = "请先加载预设或完成录入。"; return }
        let snapshot = configuration
        do {
            var nextProfiles = library, nextDevices = deviceLibrary
            guard let profileIndex = nextProfiles.profiles.firstIndex(where:{ $0.id == device.profileID && $0.modelID == device.binding.model.id }),
                  let deviceIndex = nextDevices.devices.firstIndex(where:{ $0.id == device.id }) else { throw PrivateFiles.error("当前预设或遥控器已不存在。") }
            nextProfiles.selectedID = device.profileID
            nextProfiles.profiles[profileIndex].configuration = snapshot
            nextDevices.devices[deviceIndex].configuration = snapshot
            try DevicePresetTransaction.commit(profiles:nextProfiles,devices:nextDevices,store:store,deviceStore:deviceStore)
            presetDraft = nil; library = nextProfiles; deviceLibrary = nextDevices
            rebuildRuntimes(); loadDeviceEditor()
            recordingLabel.stringValue = "整个预设已保存 · 包含所有键位、短长按、连发及圆盘设置"
        } catch {
            recordingLabel.stringValue = "保存未完成：" + error.localizedDescription
            log(recordingLabel.stringValue)
            if FileManager.default.fileExists(atPath:DevicePresetTransaction.url(store).path) { stopTest() }
        }
    }
    @objc func useAsDefault() {
        guard presetDraft == nil else { recordingLabel.stringValue = "请先保存或放弃清空草稿。"; return }
        guard let device = selectedDevice, library.containsProfile(id:device.profileID,for:device.binding.model.id) else { return }
        var next = deviceLibrary
        guard let index = next.devices.firstIndex(where:{ $0.id == device.id }) else { return }
        next.devices[index].startupProfileID = device.profileID
        if commitDevices(next) { recordingLabel.stringValue = "已设为这只遥控器的启动预设" }
    }
    @objc func repeatChanged() { let enabled = repeatToggle.state == .on; _ = editDeviceConfiguration { $0.repeatEnabled = enabled } }
    @objc func singleTriggerChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let mode = ActionTrigger(rawValue:raw),
              ActionTrigger.selectable.contains(mode), let source = UInt16(exactly:sender.tag), rows.contains(source) else { return }
        if !editDeviceConfiguration({ config in
            if config.bindings[source] == nil { config.bindings[source] = MappingConfiguration.defaultBindings[source] ?? [] }
            config.triggers[source] = mode
        }) { table.reloadData() }
    }
    func refreshLongDelayControl() {
        longDelayPopup.removeAllItems()
        let choices = Set([0.2,0.3,0.4,0.5,0.6,0.8,1.0,1.2,1.5,2.0,configuration.longPressDelay]).sorted()
        for value in choices { longDelayPopup.addItem(withTitle:String(format:"%.1f 秒",value)); longDelayPopup.lastItem?.representedObject = value }
        longDelayPopup.selectItem(at:choices.firstIndex(of:configuration.longPressDelay)!)
    }
    @objc func longDelayChanged() {
        guard let value = longDelayPopup.selectedItem?.representedObject as? Double else { return }
        _ = editDeviceConfiguration { $0.longPressDelay = value }
    }
    @objc func profileSelected() { recorder.cancel(); pendingProfileID = profilePopup.selectedItem?.representedObject as? String; refreshProfileSelection() }
    @objc func loadSelectedProfile() { if let id = pendingProfileID { loadProfile(id) } }
    func loadProfile(_ id: String) {
        guard presetDraft == nil else { recordingLabel.stringValue = "请先保存或放弃清空草稿。"; return }
        guard physicalKeys.isEmpty, let device = selectedDevice,
              let profile = library.profile(id:id,for:device.binding.model.id) else {
            recordingLabel.stringValue = "这个预设不适用于当前遥控器。"; return
        }
        recorder.cancel()
        if let selected = deviceLibrary.selectedID, let i = deviceLibrary.devices.firstIndex(where:{ $0.id == selected }) {
            var next = deviceLibrary; next.devices[i].profileID = id; next.devices[i].configuration = RemoteButtonLayout.configuration(profile.configuration,for:next.devices[i].binding.model)
            _ = commitDevices(next)
        } else {
            do { try library.select(id,for:device.binding.model.id) } catch { return }
            configuration = profile.configuration; pendingProfileID = id
            table.reloadData(); refreshProfileControls()
        }
    }
    @objc func menuProfileSelected(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { loadProfile(id) } }
    private func askProfileName(title: String, initial: String) -> String? {
        guard physicalKeys.isEmpty else { recordingLabel.stringValue = "请先松开遥控器按键。"; return nil }
        recorder.cancel()
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = "预设保存在独立的模式库中，删除设备时也会保留。"
        let name = NSTextField(string:initial); name.frame = NSRect(x:0,y:0,width:320,height:26)
        alert.accessoryView = name; alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"取消"); alert.window.initialFirstResponder = name
        return alert.runModal() == .alertFirstButtonReturn ? name.stringValue : nil
    }
    @objc func saveNewProfile() {
        guard let name = askProfileName(title:"将当前键位另存为新预设",initial:"新预设") else { return }
        guard let device = selectedDevice else { return }
        let modelID = device.binding.model.id
        let snapshot = configuration, id = UUID().uuidString
        do {
            var nextProfiles = library, nextDevices = deviceLibrary
            nextProfiles.profiles.append(.init(id:id,name:name.trimmingCharacters(in:.whitespacesAndNewlines),modelID:modelID,configuration:snapshot))
            nextProfiles.selectedID = id
            guard let index = nextDevices.devices.firstIndex(where:{ $0.id == device.id }) else { throw PrivateFiles.error("当前遥控器已不存在。") }
            nextDevices.devices[index].profileID = id; nextDevices.devices[index].configuration = snapshot
            try DevicePresetTransaction.commit(profiles:nextProfiles,devices:nextDevices,store:store,deviceStore:deviceStore)
            presetDraft = nil; library = nextProfiles; deviceLibrary = nextDevices; pendingProfileID = id
            rebuildRuntimes(); loadDeviceEditor()
            recordingLabel.stringValue = "已另存并加载新预设"
        } catch {
            recordingLabel.stringValue = "另存未完成：" + error.localizedDescription; log(recordingLabel.stringValue)
            if FileManager.default.fileExists(atPath:DevicePresetTransaction.url(store).path) { stopTest() }
        }
    }
    @objc func renameProfile() {
        guard let id = pendingProfileID, let profile = visibleProfiles.first(where:{ $0.id == id }),
              let name = askProfileName(title:"重命名当前预设",initial:profile.name) else { return }
        _ = editProfiles { lib in try lib.select(id,for:profile.modelID!); try lib.renameSelected(name) }
    }
    @objc func addBuiltInPreset(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let preset = BuiltInPreset(rawValue:value) else { return }
        var addedID: String?
        if editProfiles({ lib in try lib.addBuiltIn(preset,selecting:true); addedID = lib.selectedID }), let addedID { loadProfile(addedID) }
    }
    @objc func deleteProfile() {
        guard presetDraft == nil else { recordingLabel.stringValue = "请先保存或放弃清空草稿。"; return }
        guard let id = pendingProfileID, let profile = visibleProfiles.first(where:{ $0.id == id }) else { return }
        guard !deviceLibrary.devices.contains(where:{ $0.startupProfileID == id }) else {
            recordingLabel.stringValue = "请先为使用这个预设的遥控器指定其他启动预设。"; return
        }
        let users = deviceLibrary.devices.filter { $0.profileID == id }
        let alert = NSAlert(); alert.messageText = "删除“\(profile.name)”模式？"
        alert.informativeText = users.isEmpty ? "删除这个预设，其他预设会保留。" : "\(users.map(\.name).joined(separator:"、")) 正在使用这个预设。删除后会回到各自的启动预设。"
        alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"删除模式")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        _ = editProfiles(removedProfileIDs:[id]) { try $0.delete(id) }
    }

    @objc func clearCurrentPreset() {
        guard presetDraft == nil, let device = selectedDevice else { return }
        guard physicalKeys.isEmpty else { recordingLabel.stringValue = "请先松开遥控器按键。"; return }
        let draft = PresetDraftSession(deviceID:device.id,profileID:device.profileID,configuration:configuration,model:device.binding.model)
        presetDraft = draft; configuration = draft.configuration
        previewDeviceConfiguration(draft.configuration,for:device.id)
        recorder.cancel(); table.reloadData(); refreshTouchControls(); refreshProfileControls()
        recordingLabel.stringValue = "已清空当前草稿；保存前不会改写预设或设备键位。"
    }

    @objc func clearCurrentProfile() { clearCurrentPreset() }

    func discardPresetDraft() {
        guard let draft = presetDraft else { return }
        presetDraft = nil
        if let device = deviceLibrary.devices.first(where:{ $0.id == draft.deviceID }) {
            configuration = device.configuration
            previewDeviceConfiguration(device.configuration,for:device.id)
        }
        table.reloadData(); refreshTouchControls(); refreshProfileControls()
        recordingLabel.stringValue = "已放弃清空草稿，原键位保持不变。"
    }
    @objc func discardCurrentPreset() { discardPresetDraft() }
}
