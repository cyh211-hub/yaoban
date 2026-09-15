import AppKit

// Developer-only, isolated preview export. Never reachable in a live service.
extension LabApp {
    func exportPreviewChecksIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard isPreview, let index = args.firstIndex(of:"--preview-export"), args.indices.contains(index + 1) else { return false }
        let directory = URL(fileURLWithPath:args[index + 1],isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            window.setContentSize(NSSize(width:1380,height:940))
            try exportPreviewPage(4,to:directory.appendingPathComponent("devices-empty.png"))
            let picker = AddDeviceModelPicker(), beforePreview = deviceLibrary
            guard picker.models == [.xiaomi,.apple], picker.view.arrangedSubviews.count == 1 else { throw PrivateFiles.error("添加型号列表或小米初始键位错误。") }
            try exportModelPicker(picker,to:directory.appendingPathComponent("add-xiaomi.png"))
            picker.chooser.selectItem(at:1)
            guard picker.model == .apple, picker.view.arrangedSubviews.count == 1, deviceLibrary == beforePreview else { throw PrivateFiles.error("型号切换未显示对应按键，或预览修改了设备库。") }
            try exportModelPicker(picker,to:directory.appendingPathComponent("add-apple.png"))
            var next = deviceLibrary
            next.devices.append(SavedRemote(name:"小米 2 Pro · 演示",binding:RemoteBinding(peripheralID:UUID(),hidIdentity:"ble:1",modelID:RemoteModel.xiaomi.id),profileID:library.selectedID,configuration:configuration))
            next.devices.append(SavedRemote(name:"Apple Siri Remote · 演示",binding:RemoteBinding(peripheralID:nil,hidIdentity:"apple3loc:999",modelID:RemoteModel.apple.id),profileID:BuiltInPreset.appleCodex.id,configuration:BuiltInPreset.appleCodex.configuration))
            next.selectedID = next.devices[0].id
            guard commitDevices(next) else { throw PrivateFiles.error("预览添加模拟失败。") }
            let firstID = next.devices[0].id, secondID = next.devices[1].id
            let firstOriginal = next.devices[0].configuration
            guard changeBinding([0xE0,0x28],for:0x28), configuration.bindings[0x28] == [0xE0,0x28],
                  deviceLibrary.devices[1].configuration == BuiltInPreset.appleCodex.configuration else { throw PrivateFiles.error("设备编辑隔离检查失败。") }
            let beforeSavingTemplate = library.selected.configuration
            guard beforeSavingTemplate == firstOriginal else { throw PrivateFiles.error("自动保存误改了预设。") }
            saveCurrentProfile()
            guard library.selected.configuration.bindings[0x28] == [0xE0,0x28],
                  deviceLibrary.devices[1].configuration == BuiltInPreset.appleCodex.configuration else { throw PrivateFiles.error("预设保存隔离检查失败。") }
            editingDevicePopup.selectItem(at:1); editingDeviceSelected(editingDevicePopup)
            guard selectedDevice?.id == secondID, configuration == BuiltInPreset.appleCodex.configuration, deviceLibrary.devices.filter(\.enabled).count == 1, deviceLibrary.activeID == secondID else { throw PrivateFiles.error("切换设备覆盖了键位或保留了双设备运行。") }
            loadProfile(BuiltInPreset.applePPT.id)
            guard configuration == BuiltInPreset.applePPT.configuration, deviceLibrary.devices[0].configuration.bindings[0x28] == [0xE0,0x28] else {
                throw PrivateFiles.error("加载预设影响了其他设备。")
            }
            guard reloadSavedMappings(), selectedDevice?.id == secondID, configuration == BuiltInPreset.applePPT.configuration else { throw PrivateFiles.error("重新载入后设备键位丢失。") }
            try exportPreviewPage(0,to:directory.appendingPathComponent("apple-keys.png"))
            guard touchControls?.isHidden == false else { throw PrivateFiles.error("Apple 圆盘控件未显示。") }
            touchModePopup.selectItem(at:1); touchModeChanged()
            touchSpeedSlider.doubleValue = 1.7; touchSpeedChanged()
            guard configuration.touch == RemoteTouchSettings(mode:.pointer,speed:1.7),
                  library.selected.configuration.touch.mode == .off,
                  deviceLibrary.devices[0].configuration.touch.mode == .off else { throw PrivateFiles.error("圆盘编辑未自动保存，或改写其他配置。") }
            saveCurrentProfile()
            guard reloadSavedMappings(), configuration.touch == RemoteTouchSettings(mode:.pointer,speed:1.7),
                  library.selected.configuration.touch == configuration.touch else { throw PrivateFiles.error("圆盘模式保存或重开丢失。") }
            window.setContentSize(NSSize(width:1120,height:780))
            try exportPreviewPage(0,to:directory.appendingPathComponent("apple-touch-minimum.png"))
            guard let size = window.contentView?.bounds.size, size.width <= 1120.5, size.height <= 780.5 else { throw PrivateFiles.error("按键页不能缩小到声明的最小窗口。") }
            window.setContentSize(NSSize(width:1380,height:940))
            guard rows.count == 12, sourceName(RemoteButtonLayout.playPause) == "播放 / 暂停", !rows.contains(0x66) else { throw PrivateFiles.error("Apple 按键布局错误。") }
            let rowSwitch = NSButton(); rowSwitch.tag = 0
            editListedDevice(rowSwitch)
            guard touchControls?.isHidden == true else { throw PrivateFiles.error("小米错误显示圆盘控件。") }
            guard selectedDevice?.id == firstID, deviceLibrary.activeID == firstID,
                  deviceLibrary.devices.filter(\.enabled).count == 1, !originalBindingButton.isHidden else { throw PrivateFiles.error("列表切换按钮未切换实际使用设备。") }
            try exportPreviewPage(4,to:directory.appendingPathComponent("devices-two.png"))
            try exportPreviewPage(0,to:directory.appendingPathComponent("device-keys.png"))
            window.setContentSize(NSSize(width:1120,height:780))
            try exportPreviewPage(4,to:directory.appendingPathComponent("devices-minimum.png"))
            // Rendering/export never creates runtime objects or opens event taps.
            guard runtimes.isEmpty, !emitter.isObserving, !recorder.isActive else { throw PrivateFiles.error("预览隔离检查失败。") }
            print("PASS: real UI delegates auto-save independent device keys, explicitly save templates, switch one active device, load/reload Xiaomi and Apple presets; no hardware runtime or global event tap")
            print("PASS: isolated native UI rendered empty/two-device/key/minimum-size pages")
        } catch { print("FAIL: preview checks: \(error)"); exit(1) }
        NSApp.terminate(nil); return true
    }
    private func exportModelPicker(_ picker: AddDeviceModelPicker, to url: URL) throws {
        let alert = NSAlert(); alert.messageText = "选择遥控器型号"
        alert.accessoryView = picker.view; alert.addButton(withTitle:"下一步"); alert.addButton(withTitle:"取消")
        alert.layout()
        guard let view = alert.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw PrivateFiles.error("无法渲染添加界面。") }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw PrivateFiles.error("无法导出添加界面。") }
        try data.write(to:url)
        alert.accessoryView = nil
    }
    private func exportPreviewPage(_ index: Int, to url: URL) throws {
        selectPage(index)
        window.contentView?.layoutSubtreeIfNeeded()
        if index == 0 { table.reloadData(); table.enclosingScrollView?.tile(); table.layoutSubtreeIfNeeded() }
        window.displayIfNeeded()
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw PrivateFiles.error("无法渲染界面。") }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw PrivateFiles.error("无法导出界面。") }
        try data.write(to:url)
    }
}
