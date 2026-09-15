import AppKit

extension LabApp {
    func displayName(for item: SavedRemote) -> String {
        let base = runtimes[item.id]?.systemName ?? item.name
        let sameName = deviceLibrary.devices.filter { (runtimes[$0.id]?.systemName ?? $0.name) == base }
        guard sameName.count > 1, let position = sameName.firstIndex(where:{ $0.id == item.id }) else { return base }
        return base + " · \(position + 1)"
    }
    func syncSystemDeviceNames() {
        guard !isPreview,storageReady,!FileManager.default.fileExists(atPath:DevicePresetTransaction.url(store).path) else { return }
        var next = deviceLibrary
        for index in next.devices.indices {
            if let name = runtimes[next.devices[index].id]?.systemName { next.devices[index].name = name }
        }
        guard next != deviceLibrary else { return }
        do {
            // Metadata-only save: don't cancel a held key, reload a preset or restart input.
            try deviceStore.save(next)
            deviceLibrary = next
            for item in next.devices { runtimes[item.id]?.record.name = item.name }
            refreshDeviceStatus(); makeStatusMenu()
        } catch { log("系统设备名称暂未保存：" + error.localizedDescription) }
    }
    func restoreMappingJournals() throws {
        try mapper.restore()
        for url in try FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:nil) {
            let name = url.lastPathComponent
            guard name.hasPrefix("mapping-restore-"), name.hasSuffix(".json"),
                  UUID(uuidString:String(name.dropFirst("mapping-restore-".count).dropLast(5))) != nil else { continue }
            let recovery = DeviceMapper(journalURL:url); recovery.log = mapper.log
            try recovery.restore()
        }
    }
    func rebuildRuntimes() {
        guard !isPreview else { refreshDeviceList(); return }
        for runtime in runtimes.values {
            runtime.selectedForInput = runtime.id == deviceLibrary.activeID
            if !runtime.selectedForInput && (runtime.running || runtime.restoreFailure != nil) {
                runtime.stop()
                if let failure = runtime.restoreFailure { stopped = true; log("切换已暂停：" + failure); return }
            }
        }
        for id in Array(runtimes.keys) where !deviceLibrary.devices.contains(where:{ $0.id == id }) {
            runtimes.removeValue(forKey:id)?.stop()
        }
        for item in deviceLibrary.devices {
            guard item.binding.isBound else { runtimes.removeValue(forKey:item.id)?.stop(); continue }
            if let previous = runtimes[item.id], previous.record.binding != item.binding {
                previous.stop(); runtimes.removeValue(forKey:item.id)
            }
            if let runtime = runtimes[item.id] {
                runtime.selectedForInput = item.id == deviceLibrary.activeID
                if runtime.record != item {
                    let enabledChanged = runtime.record.enabled != item.enabled
                    if enabledChanged { runtime.stop() }
                    runtime.update(item)
                    if enabledChanged && item.enabled && !stopped && !isPreview { runtime.start() }
                }
                continue
            }
            let runtime = RemoteRuntime(record:item,directory:output,emitter:emitter,outputOwners:outputOwners,voiceOwners:voiceOwners,systemMic:systemMic)
            runtime.selectedForInput = item.id == deviceLibrary.activeID
            runtime.log = { [weak self, weak runtime] text in self?.log("[\(runtime?.record.name ?? "遥控器")] " + text) }
            runtime.changed = { [weak self] in self?.refreshDeviceStatus() }
            runtime.canRecordVoice = { [weak self] in self?.recorder.isActive == false && self?.recordingSource == nil && self?.recordingTouchGesture == nil && self?.stopped == false }
            runtime.keysChanged = { [weak self, weak runtime] old,next in
                guard let self, let runtime else { return }
                if self.recorder.isActive && !next.subtracting(old).isEmpty {
                    self.recorder.cancel("请按电脑键盘录入目标键；此次遥控器按键未保存。")
                    runtime.release(blocking:next)
                }
                if self.deviceLibrary.selectedID == runtime.id {
                    self.keyLabel.stringValue = "当前按键：" + (next.isEmpty ? "无" : next.sorted().map { RemoteButtonLayout.name($0,model:runtime.record.binding.model) }.joined(separator:" + "))
                    if next.contains(0x3E) && !old.contains(0x3E) { self.calibration.observeRemoteMicrophoneDown() }
                }
            }
            runtime.ble.diagnostics = diagnostics
            runtime.ble.saved = { [weak self] in self?.latestRecording = $0 }
            runtime.ble.meter = { [weak self, weak runtime] seconds,peak in
                guard let self, self.voiceOwners.owner == runtime?.id else { return }
                self.levelLabel.stringValue = seconds > 0 ? String(format:"收音：%.1f 秒 · 原声峰值 %.0f%%",seconds,peak * 100) : "收音：等待麦克风按键"
            }
            runtime.microphoneEnabled = audioToggle.state == .on
            runtimes[item.id] = runtime
        }
        refreshDeviceList()
    }
    func loadDeviceEditor() {
        recorder.cancel(); calibration.stop()
        if let item = selectedDevice {
            if let draft = presetDraft, draft.deviceID == item.id { configuration = draft.configuration }
            else { configuration = item.configuration }
            if library.containsProfile(id:item.profileID,for:item.binding.model.id) { library.selectedID = item.profileID }
        } else { configuration = library.selected.configuration }
        pendingProfileID = library.selectedID
        originalBindingButton.isHidden = binding?.model == .apple
        testToggle.state = selectedRuntime?.ble.testingEnabled == true ? .on : .off
        table.reloadData(); refreshProfileControls(); refreshTouchControls(); refreshDeviceStatus(); refreshDeviceList()
    }
    func previewDeviceConfiguration(_ preview: MappingConfiguration, for deviceID: UUID) {
        guard let item = deviceLibrary.devices.first(where:{ $0.id == deviceID }), let runtime = runtimes[deviceID] else { return }
        var record = item; record.configuration = preview
        runtime.update(record)
    }
    @discardableResult func commitDevices(_ proposed: RemoteDeviceLibrary) -> Bool {
        var next = proposed; next.normalizeSelection()
        if let draft = presetDraft, next.selectedID != draft.deviceID {
            recordingLabel.stringValue = "当前清空草稿尚未保存；请先保存或放弃，再切换遥控器。"
            return false
        }
        guard storageReady, !FileManager.default.fileExists(atPath:DevicePresetTransaction.url(store).path) else {
            log("设置尚未恢复，请先重新检测。"); return false
        }
        let previouslyRunning = Set(runtimes.values.filter(\.running).map(\.id))
        do {
            _ = try next.validated()
            // Release and restore removed/re-associated devices before committing
            // removal. On failure the record remains available for a retry.
            for runtime in runtimes.values where (runtime.running || runtime.restoreFailure != nil) && (!next.devices.contains(where:{ $0.id == runtime.id && $0.binding == runtime.record.binding }) || runtime.id != next.activeID) {
                runtime.stop()
                if let failure = runtime.restoreFailure { throw PrivateFiles.error(failure) }
            }
            try deviceStore.save(next); deviceLibrary = next
            rebuildRuntimes(); loadDeviceEditor()
            if !stopped, let active = next.activeID { runtimes[active]?.start() }
            return true
        } catch {
            // A failed write must not silently leave the previous input service
            // stopped. Restart only when disk still confirms the old binding.
            if !stopped, !previouslyRunning.isEmpty,
               runtimes.values.allSatisfy({ $0.restoreFailure == nil }),
               let data = try? PrivateFiles.read(deviceStore.directory.appendingPathComponent("设备库.json")),
               let saved = try? JSONDecoder().decode(RemoteDeviceLibrary.self,from:data).validated(), saved == deviceLibrary {
                for id in previouslyRunning { runtimes[id]?.start() }
            }
            recordingLabel.stringValue = "设备设置未保存：" + error.localizedDescription
            log(recordingLabel.stringValue); return false
        }
    }
    @discardableResult func commitProfilesAndDevices(_ proposedProfiles: MappingLibrary, _ proposedDevices: RemoteDeviceLibrary) -> Bool {
        var nextDevices = proposedDevices; nextDevices.normalizeSelection()
        if let draft = presetDraft, nextDevices.selectedID != draft.deviceID {
            recordingLabel.stringValue = "当前清空草稿尚未保存；请先保存或放弃，再切换遥控器。"; return false
        }
        guard storageReady, !FileManager.default.fileExists(atPath:DevicePresetTransaction.url(store).path) else {
            log("设置尚未恢复，请先重新检测。"); return false
        }
        do {
            for runtime in runtimes.values where (runtime.running || runtime.restoreFailure != nil) && (!nextDevices.devices.contains(where:{ $0.id == runtime.id && $0.binding == runtime.record.binding }) || runtime.id != nextDevices.activeID) {
                runtime.stop()
                if let failure = runtime.restoreFailure { throw PrivateFiles.error(failure) }
            }
            try DevicePresetTransaction.commit(profiles:proposedProfiles,devices:nextDevices,store:store,deviceStore:deviceStore)
            library = proposedProfiles; deviceLibrary = nextDevices
            rebuildRuntimes(); loadDeviceEditor()
            if !stopped, let active = nextDevices.activeID { runtimes[active]?.start() }
            return true
        } catch {
            recordingLabel.stringValue = "预设与设备未保存：" + error.localizedDescription
            log(recordingLabel.stringValue)
            if FileManager.default.fileExists(atPath:DevicePresetTransaction.url(store).path) { stopTest() }
            return false
        }
    }
    @discardableResult func editDeviceConfiguration(_ operation: (inout MappingConfiguration) throws -> Void) -> Bool {
        guard let id = selectedDevice?.id, let index = deviceLibrary.devices.firstIndex(where:{ $0.id == id }) else {
            recordingLabel.stringValue = "先添加遥控器，再编辑它的键位；内置模式可先查看。"; return false
        }
        guard physicalKeys.isEmpty else { recordingLabel.stringValue = "请先松开遥控器按键。"; return false }
        do {
            if var draft = presetDraft {
                guard draft.deviceID == id else { throw PrivateFiles.error("清空草稿属于另一只遥控器，请先放弃或保存。") }
                try operation(&draft.configuration)
                draft.configuration = try draft.configuration.validated()
                presetDraft = draft; configuration = draft.configuration
                previewDeviceConfiguration(draft.configuration,for:id)
                table.reloadData(); refreshProfileControls(); refreshTouchControls()
                recordingLabel.stringValue = "正在编辑未保存的清空草稿"
                return true
            }
            var next = deviceLibrary
            try operation(&next.devices[index].configuration)
            next.devices[index].configuration = try next.devices[index].configuration.validated()
            guard commitDevices(next) else { return false }
            recordingLabel.stringValue = "此设备的键位已自动保存 · 点击“保存模式”可更新预设，供其他设备加载"
            return true
        } catch { recordingLabel.stringValue = "修改未保存：" + error.localizedDescription; return false }
    }
    @objc func editingDeviceSelected(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String, let id = UUID(uuidString:value) else { return }
        var next = deviceLibrary; next.selectDevice(id); _ = commitDevices(next)
    }
    @objc func menuDeviceSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString:value),
              deviceLibrary.devices.contains(where:{ $0.id == id && $0.binding.model.supported }) else { return }
        var next = deviceLibrary; next.selectDevice(id)
        if !commitDevices(next) { showMainWindow() }
    }
    @objc func editListedDevice(_ sender: NSButton) {
        guard deviceLibrary.devices.indices.contains(sender.tag) else { return }
        var next = deviceLibrary; next.selectDevice(next.devices[sender.tag].id)
        if commitDevices(next) { showKeyPage() }
    }
    @objc func toggleListedDevice(_ sender: NSButton) {
        guard deviceLibrary.devices.indices.contains(sender.tag) else { return }
        var next = deviceLibrary; if sender.state == .on { next.selectDevice(next.devices[sender.tag].id) }
        else { next.devices[sender.tag].enabled = false }
        _ = commitDevices(next)
    }
    @objc func deleteListedDevice(_ sender: NSButton) {
        guard deviceLibrary.devices.indices.contains(sender.tag) else { return }
        let item = deviceLibrary.devices[sender.tag]
        let alert = NSAlert(); alert.messageText = "删除“\(displayName(for:item))”？"
        alert.informativeText = "会停止这只遥控器的输入并移出设备列表。已保存的预设会保留。系统蓝牙配对由你在系统设置中管理。"
        alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"删除设备，保留键位")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        var next = deviceLibrary
        do { try next.remove(item.id); _ = commitDevices(next) }
        catch { log(error.localizedDescription) }
    }
    func refreshDeviceList() {
        let signature = deviceLibrary.devices.map { item in
            "\(item.id):\(item.binding.hidIdentity):\(item.binding.peripheralID?.uuidString ?? ""):\(displayName(for:item)):\(item.enabled):\(runtimes[item.id]?.connected == true):\(runtimes[item.id]?.ble.needsBindingSelection == true)"
        }.joined() + "\(deviceLibrary.selectedID?.uuidString ?? "empty")\(stopped)"
        guard signature != lastDeviceListSignature else { return }; lastDeviceListSignature = signature
        editingDevicePopup.removeAllItems()
        for item in deviceLibrary.devices {
            editingDevicePopup.addItem(withTitle:displayName(for:item))
            editingDevicePopup.lastItem?.representedObject = item.id.uuidString
            if item.id == deviceLibrary.selectedID { editingDevicePopup.selectItem(at:editingDevicePopup.numberOfItems - 1) }
        }
        if deviceLibrary.devices.isEmpty { editingDevicePopup.addItem(withTitle:"尚未添加遥控器") }
        editingDevicePopup.isEnabled = !deviceLibrary.devices.isEmpty
        for view in deviceList.arrangedSubviews { deviceList.removeArrangedSubview(view); view.removeFromSuperview() }
        if deviceLibrary.devices.isEmpty {
            deviceList.addArrangedSubview(label("还没有遥控器\n添加第一只设备后，即可加载 Codex 或 PPT 预设。",size:16,secondary:true))
        }
        for (index,item) in deviceLibrary.devices.enumerated() {
            let runtime = runtimes[item.id]
            let status = !item.binding.isBound ? "未绑定设备" : item.id != deviceLibrary.selectedID ? "待切换" : !item.enabled ? "已暂停" : stopped ? "服务已暂停" : runtime?.ble.needsBindingSelection == true ? "需重新配对" : runtime?.connected == true ? "已连接" : "未连接"
            let bindingPicker = BluetoothBindingPicker(model:item.binding.model,current:item.binding) { [weak self] in
                self?.availableBindings(for:item.binding.model,replacing:item.id) ?? []
            }
            bindingPicker.didSelect = { [weak self] value in
                _ = self?.saveRemoteBinding(value,model:item.binding.model,replacing:item.id)
            }
            let remove = button("删除…",#selector(deleteListedDevice(_:))); remove.tag = index
            let row = horizontal([vertical([label(displayName(for:item),size:15,weight:.medium),label("\(item.binding.model.title) · \(status)",size:12,secondary:true)],spacing:5),spring(),bindingPicker,remove])
            deviceList.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:deviceList.widthAnchor).isActive = true
        }
    }
}
