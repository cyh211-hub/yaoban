// Xiaomi Remote Lab — GPL-3.0.
import AppKit
import IOKit.hid

final class LabApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let systemMic = SystemMicrophone()
    let emitter = KeyboardEmitter()
    let calibration = KeyCalibration()
    let recorder = ShortcutRecorder()
    var mapper: DeviceMapper!
    var store: MappingStore!
    let instanceLease = InstanceLease()
    var secondaryInstance = false
    var configuration = MappingConfiguration()
    var library = MappingLibrary()
    let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var pendingProfileID: String?
    let loadProfileButton = NSButton(title: "加载", target: nil, action: nil)
    let saveProfileButton = NSButton(title: "保存", target: nil, action: nil)
    let deleteProfileButton = NSButton(title: "删除", target: nil, action: nil)
    let profileSelectionLabel = NSTextField(wrappingLabelWithString: "")
    let currentModeLabel = NSTextField(labelWithString: "")
    let modeMoreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let deviceTitle = NSTextField(labelWithString: "未选择遥控器")
    let deviceConnection = NSTextField(labelWithString: "正在检测")
    let deviceChannels = NSTextField(labelWithString: "")
    let batteryLabel = NSTextField(labelWithString:"电量未知")
    var batteryIconView: NSImageView?
    let deviceHint = NSTextField(wrappingLabelWithString: "")
    var lastDeviceStatus: RemoteDeviceStatus?
    var devicePhotoView: NSView?
    let setupPermissionLabel = NSTextField(wrappingLabelWithString:"")
    let inputPermissionStatus = NSTextField(labelWithString: "")
    let outputPermissionStatus = NSTextField(labelWithString: "")
    let inputPermissionButton = NSButton(title:"打开设置",target:nil,action:nil)
    let outputPermissionButton = NSButton(title:"打开设置",target:nil,action:nil)
    let privacyLabel = NSTextField(wrappingLabelWithString:"")
    let isFirstRunPreview = ProcessInfo.processInfo.arguments.contains("--preview-first-run") || Bundle.main.object(forInfoDictionaryKey:"YaobanFirstRunPreview") as? Bool == true
    var configURL: URL!
    var output: URL!
    var window: NSWindow!
    var statusItem: NSStatusItem?
    let table = NSTableView()
    var rows: [UInt16] { selectedDevice.map { RemoteButtonLayout.rows(for:$0.binding.model) } ?? [] }
    func sourceName(_ source: UInt16) -> String { RemoteButtonLayout.name(source,model:binding?.model ?? .xiaomi) }
    let recordingLabel = NSTextField(labelWithString: "选择映射菜单以修改按键。")
    let cancelRecordingButton = NSButton(title: "取消录入", target: nil, action: nil)
    let originalBindingButton = NSButton(title:"保持原键",target:nil,action:nil)
    var presetDraft: PresetDraftSession?
    var recordingTouchGesture: RemoteTouchGesture?
    var touchGesturePopups: [RemoteTouchGesture:NSPopUpButton] = [:]
    var recordingSource: UInt16?
    var recordingTicket = UUID()
    var recordingLongPress = false
    var selectedBindingIsLong = false
    let longDelayPopup = NSPopUpButton(frame:.zero,pullsDown:false)
    let touchModePopup = NSPopUpButton(frame:.zero,pullsDown:false)
    let touchSpeedSlider = NSSlider(value:1,minValue:0.5,maxValue:3,target:nil,action:nil)
    let touchSpeedLabel = NSTextField(labelWithString:"1.0 倍")
    let touchStatusLabel = NSTextField(labelWithString:"已关闭")
    var touchControls: NSView?
    var recordingPreview = ""
    let mappingLabel = NSTextField(labelWithString: "映射：正在检测")
    let outputLabel = NSTextField(labelWithString: "输出：等待遥控器按键")
    let hidLabel = NSTextField(labelWithString: "按键：尚未开始")
    let bleLabel = NSTextField(labelWithString: "遥控器音频：尚未开始")
    let keyLabel = NSTextField(labelWithString: "当前按键：无")
    let levelLabel = NSTextField(labelWithString: "收音：未开始")
    let systemMicLabel = NSTextField(labelWithString: "系统麦克风：正在检测")
    let audioToggle = NSButton(checkboxWithTitle: "启用遥控器麦克风", target: nil, action: nil)
    let gainLabel = NSTextField(labelWithString: "音量增强：12 dB")
    let gainSlider = NSSlider(value: 12, minValue: 0, maxValue: 24, target: nil, action: nil)
    let logView = NSTextView()
    let testToggle = NSButton(checkboxWithTitle: "保存原声录音用于试听（默认关闭；单次最多 60 秒，保留 7 天）", target: nil, action: nil)
    var diagnostics: DiagnosticsStore?
    var deviceStore: RemoteDeviceStore!
    var storageReady = false
    var profilesLoaded = false
    var deviceLibrary = RemoteDeviceLibrary()
    var runtimes: [UUID:RemoteRuntime] = [:]
    let discovery = BLEProbe()
    let outputOwners = RemoteOutputOwnership()
    let voiceOwners = RemoteVoiceOwnership()
    var selectedDevice: SavedRemote? { deviceLibrary.selected }
    var selectedRuntime: RemoteRuntime? { deviceLibrary.selectedID.flatMap { runtimes[$0] } }
    var binding: RemoteBinding? { selectedDevice?.binding }
    let deviceList = NSStackView()
    let editingDevicePopup = NSPopUpButton(frame:.zero,pullsDown:false)
    var lastDeviceListSignature = ""
    var bindingURL: URL { store.directory.appendingPathComponent("遥控器绑定.json") }
    var latestRecording: URL?
    var poll: Timer?
    var localMonitor: Any?
    var stopped = false
    var physicalKeys: Set<UInt16> { runtimes.values.reduce(into:Set<UInt16>()) { $0.formUnion($1.physicalKeys) } }
    var lastMappingStatus = ""

    let isPreview = ProcessInfo.processInfo.arguments.contains("--preview") || Bundle.main.object(forInfoDictionaryKey:"YaobanPreviewOnly") as? Bool == true
    let pageHost = NSView()
    var pages: [NSView] = []
    var pageConstraints: [[NSLayoutConstraint]] = []
    var navButtons: [NSButton] = []
    let pageTitle = NSTextField(labelWithString: "按键设置")
    let serviceBadge = NSTextField(labelWithString: "正在连接")
    var actionTimer: Timer?
    let repeatToggle = NSButton(checkboxWithTitle: "启用当前模式的长按连发", target: nil, action: nil)
    let loginToggle = NSButton(checkboxWithTitle: "登录 Mac 后自动启动", target: nil, action: nil)
    let loginLabel = NSTextField(wrappingLabelWithString: "启动后在菜单栏运行，关闭设置窗口不影响输入。")
    var sleepObserver: NSObjectProtocol?
    var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isPreview, let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.moss.MiRemoteLab")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            secondaryInstance = true
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil); return
        }
        let legacyRoot = Bundle.main.object(forInfoDictionaryKey: "LegacyWorkspaceRoot") as? String
        store = MappingStore(directory: isPreview ? URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("yaoban-preview-\(UUID().uuidString)") : MappingStore.userDirectory,
            legacyDirectory:isPreview ? nil : legacyRoot.map { URL(fileURLWithPath:$0) })
        do {
            guard try instanceLease.acquire(in: store.directory) else { secondaryInstance = true; NSApp.terminate(nil); return }
        } catch {
            secondaryInstance = true
            let alert = NSAlert(); alert.messageText = "无法打开应用设置目录"
            alert.informativeText = error.localizedDescription; alert.runModal()
            NSApp.terminate(nil); return
        }
        output = store.directory.appendingPathComponent("Diagnostics")
        configURL = store.url
        do {
            try PrivateFiles.protectTree(store.directory)
            diagnostics = try DiagnosticsStore(directory: output)
        } catch {
            let alert = NSAlert(); alert.messageText = "无法保护应用数据"
            alert.informativeText = error.localizedDescription; alert.runModal()
            secondaryInstance = true; NSApp.terminate(nil); return
        }
        deviceStore = RemoteDeviceStore(directory:store.directory)
        makeWindow()
        makeStatusMenu()
        do {
            try DevicePresetTransaction.recover(store:store,deviceStore:deviceStore)
            let loaded = try store.loadForApp()
            profilesLoaded = true
            library = loaded.library
            configuration = loaded.configuration
            try store.migrateRecoveryJournals(to: output)
            recordingLabel.stringValue = loaded.notice + " · 修改后自动保存"
            log(loaded.notice + "：" + configURL.path)
            log("已载入键位：" + configuration.bindings.sorted { $0.key < $1.key }.map { "\(RemoteButtonLayout.names[$0.key] ?? "未知") → \(KeyboardKey.describe($0.value))" }.joined(separator: "；"))
        } catch {
            configuration = MappingConfiguration(bindings: [:])
            stopped = true
            recordingLabel.stringValue = "设置读取失败，已暂停映射，原文件保留：\(error.localizedDescription)"
            recordingLabel.textColor = .systemRed
            setMappingStatus("设置读取失败，请点击重新检测；不会覆盖为默认值")
            log(recordingLabel.stringValue)
        }
        table.reloadData()
        refreshProfileControls()
        mapper = DeviceMapper(journalURL:output.appendingPathComponent("mapping-restore.json"))
        mapper.log = { [weak self] in self?.log($0) }
        // Restore the previous single-device journal before creating per-device owners.
        if !isPreview { do { try restoreMappingJournals() } catch { stopped = true; log(error.localizedDescription) } }
        deviceStore = RemoteDeviceStore(directory:store.directory)
        do {
            guard profilesLoaded else { throw PrivateFiles.error("请先恢复模式文件，再迁移设备。") }
            deviceLibrary = try deviceStore.load(migrating:bindingURL,profiles:library)
            let prepared = try DevicePresetTransaction.prepareForLaunch(profiles:library,devices:deviceLibrary,store:store,deviceStore:deviceStore)
            library = prepared.profiles; deviceLibrary = prepared.devices
            if let notice = prepared.notice { log(notice) }
            storageReady = true
        } catch { stopped = true; log("设备库读取失败，原文件保留：" + error.localizedDescription) }
        discovery.log = mapper.log
        recorder.log = mapper.log; systemMic.log = mapper.log; emitter.log = mapper.log
        systemMic.status = { [weak self] in self?.systemMicLabel.stringValue = "系统麦克风：" + $0 }
        systemMic.restoreURL = output.appendingPathComponent("audio-input-restore.json")
        systemMic.gainDB = gainSlider.doubleValue
        outputOwners.emit = { [weak self] in self?.emitter.send($0,down:$1) }
        outputOwners.pressAgain = { [weak self] in self?.emitter.repeatKey($0) }
        emitter.observationChanged = { [weak self] _ in self?.refreshPrivacyStatus() }
        emitter.status = { [weak self] in self?.outputLabel.stringValue = "输出：" + $0 }
        emitter.failed = { [weak self] reason in
            guard let self else { return }
            for runtime in self.runtimes.values { runtime.release(blocking:runtime.physicalKeys) }
            self.setMappingStatus(reason); self.refreshDeviceStatus()
        }
        recorder.preview = { [weak self] text in
            guard let self else { return }
            self.recordingPreview = text
            self.recordingLabel.stringValue = "正在录入：" + text
            self.reloadRecordingRow()
            self.refreshPrivacyStatus()
        }
        recorder.cancelled = { [weak self] reason in self?.endRecording(message: reason) }
        recorder.completed = { [weak self] keys in
            guard let self else { return }
            if let gesture = self.recordingTouchGesture {
                _ = self.editDeviceConfiguration { $0.touch.setBinding(keys,for:gesture) }
            } else if let source = self.recordingSource { _ = self.changeBinding(keys, for: source, longPress:self.recordingLongPress) }
            self.endRecording(message: self.recordingLabel.stringValue)
        }
        recorder.cancellationRect = { [weak self] in
            guard let self else { return nil }
            let button = self.cancelRecordingButton
            guard !button.isHiddenOrHasHiddenAncestor else { return nil }
            return self.window.convertToScreen(button.convert(button.bounds,to:nil))
        }
        calibration.log = mapper.log
        calibration.activityChanged = { [weak self] in self?.refreshPrivacyStatus() }
        calibration.apply = { [weak self] usage in
            guard let self else { return }
            guard let index = self.rows.firstIndex(of:0x3E) else { return }
            self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
            self.changeBinding([usage])
        }
        rebuildRuntimes()
        loadDeviceEditor()
        actionTimer = Timer(timeInterval:0.015,repeats:true) { [weak self] _ in
            guard let self else { return }; for runtime in self.runtimes.values { runtime.tick() }
        }
        RunLoop.main.add(actionTimer!,forMode:.common)
        // Observe only right-Command flags in our own focused window. Never capture text.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if event.keyCode == 54 {
                let down = (event.modifierFlags.rawValue & 0x10) != 0
                self?.log("本窗口收到右 ⌘ \(down ? "按下" : "松开")（仍需结合实体遥控器操作核对）")
            }
            return event
        }
        log("当前麦克风设置：\(configuration.bindings[0x3E].map(KeyboardKey.describe) ?? "保持原键")；按下与松开对应传递。")
        log("声音只读取遥控器蓝牙；安装系统麦克风组件后，可在系统设置和输入法中选择。")
        if isPreview {
            if exportPreviewChecksIfRequested() { return }
            serviceBadge.stringValue = "界面预览"
            if isFirstRunPreview { selectPage(4) }
            refreshDeviceStatus()
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            return
        }
        if !stopped { for runtime in runtimes.values { runtime.start() } }
        refreshMappings()
        systemMic.refresh()
        poll = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            guard let self else { return }
            self.syncSystemDeviceNames()
            self.refreshMappings(); self.systemMic.refresh()
            if !self.stopped { for runtime in self.runtimes.values where runtime.running { runtime.ble.ensureConnection() } }
            try? self.diagnostics?.maintenance()
        }
        configureLogin()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object:nil, queue:.main) { [weak self] _ in
            guard let self else { return }; self.recorder.cancel()
            for runtime in self.runtimes.values { runtime.stop() }; self.systemMic.stop()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object:nil, queue:.main) { [weak self] _ in
            guard let self, !self.stopped else { return }; self.restart()
        }
        if binding == nil { selectPage(4); showMainWindow() }
        else if ProcessInfo.processInfo.arguments.contains("--show-settings") { showMainWindow() }
        if ProcessInfo.processInfo.arguments.contains("--calibrate") { calibration.show() }
    }

    func makeStatusMenu() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = (NSImage(named: "BrandMark")?.copy() as? NSImage)
            ?? NSImage(systemSymbolName:"appletvremote.gen4.fill",accessibilityDescription:"遥伴")
        icon?.size = NSSize(width: 24, height: 24)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        let activeProfile = selectedDevice.flatMap { library.profile(id:$0.profileID,for:$0.binding.model.id) }
        item.button?.toolTip = "遥伴 · \(activeProfile?.displayName ?? "未选择预设") · \(lastDeviceStatus?.connection.rawValue ?? "正在检测")"
        let menu = NSMenu()
        menu.autoenablesItems = false
        let connected = lastDeviceStatus?.connection == .connected
        let currentName = selectedDevice.map { displayName(for:$0) } ?? "尚未添加遥控器"
        let connection = lastDeviceStatus?.connection.rawValue ?? "正在检测"
        let deviceItem = NSMenuItem(title:currentName + " · " + connection,action:nil,keyEquivalent:"")
        deviceItem.attributedTitle = NSAttributedString(string:deviceItem.title,attributes:[.foregroundColor:connected ? NSColor.systemGreen : NSColor.systemRed])
        let devicesMenu = NSMenu(); devicesMenu.autoenablesItems = false
        for device in deviceLibrary.devices {
            let choice = NSMenuItem(title:displayName(for:device),action:#selector(menuDeviceSelected(_:)),keyEquivalent:"")
            choice.target = self; choice.representedObject = device.id.uuidString
            choice.state = device.id == selectedDevice?.id ? .on : .off
            choice.isEnabled = storageReady && presetDraft == nil && device.binding.model.supported
            devicesMenu.addItem(choice)
        }
        deviceItem.submenu = devicesMenu
        deviceItem.isEnabled = !deviceLibrary.devices.isEmpty
        menu.addItem(deviceItem)
        func statusLine(_ text:String,_ ready:Bool) {
            let row = NSMenuItem(title:text,action:nil,keyEquivalent:"")
            let label = NSTextField(labelWithString:text)
            label.font = .menuFont(ofSize:0); label.textColor = ready ? .systemGreen : .systemRed
            label.sizeToFit()
            let container = NSView(frame:NSRect(x:0,y:0,width:max(250,label.frame.width+36),height:28))
            label.frame.origin = NSPoint(x:18,y:6); container.addSubview(label); row.view = container
            row.isEnabled = false; menu.addItem(row)
        }
        let granted = isPreview || (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted && CGPreflightPostEventAccess())
        statusLine("权限：" + (granted ? "已授权 ✓" : "待授权"),granted)
        menu.addItem(.separator())
        let modeItem = NSMenuItem(title:"加载预设",action:nil,keyEquivalent:"")
        let modeMenu = NSMenu()
        for profile in visibleProfiles {
            let entry = NSMenuItem(title:profile.displayName,action:#selector(menuProfileSelected(_:)),keyEquivalent:"")
            entry.target = self; entry.representedObject = profile.id; entry.state = profile.id == selectedDevice?.profileID ? .on : .off
            modeMenu.addItem(entry)
        }
        modeItem.submenu = modeMenu; modeItem.isEnabled = !visibleProfiles.isEmpty; menu.addItem(modeItem)
        for (title,action) in [("系统检查…",#selector(showSystemCheck)),("设置…",#selector(showMainWindow))] {
            let entry = NSMenuItem(title:title,action:action,keyEquivalent:""); entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title:"退出",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"")
        quit.target = NSApp; menu.addItem(quit)
        item.menu = menu; statusItem = item
    }
    @objc func showMainWindow() {
        if !hasUnsavedPresetDraft { reloadSavedMappings() }
        if !isPreview { refreshLoginState() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func tableViewSelectionDidChange(_ notification: Notification) { recorder.cancel(); selectedBindingIsLong = false }
    @objc func selectMappingCell() { selectedBindingIsLong = table.clickedColumn == 3 && configuration.trigger(for:selectedUsage) == .shortLong }
    var selectedUsage: UInt16 { rows.isEmpty ? 0 : rows[min(rows.count - 1,max(0, table.selectedRow))] }
    func reloadRecordingRow() {
        if recordingTouchGesture != nil { refreshTouchControls() }
        // Refresh only the active cell: a full reload can cancel capture.
        if let source = recordingSource, let row = rows.firstIndex(of:source) {
            table.reloadData(forRowIndexes:IndexSet(integer:row),columnIndexes:IndexSet(integer:recordingLongPress ? 3 : 2))
        }
    }
    func endRecording(message: String) {
        recordingTicket = UUID()
        let old = recordingSource, wasLong = recordingLongPress
        recordingSource = nil; recordingTouchGesture = nil; recordingLongPress = false; recordingPreview = ""
        refreshTouchControls()
        if let old, let row = rows.firstIndex(of:old) {
            table.reloadData(forRowIndexes:IndexSet(integer:row),columnIndexes:IndexSet(integer:wasLong ? 3 : 2))
        }
        cancelRecordingButton.isHidden = true; recordingLabel.stringValue = message
        refreshPrivacyStatus()
        if storageReady { refreshMappings() }
    }
    @objc func cancelRecording() { recorder.cancel() }
    @discardableResult func reloadSavedMappings() -> Bool {
        guard store != nil, deviceStore != nil else { return false }
        do {
            try DevicePresetTransaction.recover(store:store,deviceStore:deviceStore)
            library = try store.load().library
            deviceLibrary = try deviceStore.load(migrating:bindingURL,profiles:library)
            storageReady = true
            rebuildRuntimes()
            // Device snapshots are the source of active keys, not a mutable preset.
            loadDeviceEditor(); return true
        } catch { log("模式读取失败，原文件保留：" + error.localizedDescription); return false }
    }
    @discardableResult func changeBinding(_ keys: [UInt16]?, for source: UInt16? = nil, longPress: Bool = false) -> Bool {
        let usage = source ?? selectedUsage
        return editDeviceConfiguration { config in
            if longPress { config.longBindings[usage] = KeyboardKey.normalized(keys ?? []) }
            else {
                config.bindings[usage] = keys.map(KeyboardKey.normalized)
                if keys == nil { config.triggers[usage] = .hold }
            }
        }
    }
    @objc func originalBinding() {
        recorder.cancel(); selectedBindingIsLong = false
        guard binding?.model != .apple else { recordingLabel.stringValue = "Apple 按键采用独占映射；请选择目标键或禁用映射。切换到其他遥控器后恢复 Apple 的系统处理。"; return }
        changeBinding(nil)
    }
    @objc func disableBinding() { let isLong = selectedBindingIsLong; recorder.cancel(); changeBinding([],longPress:isLong) }

    func refreshMappings() {
        guard !isPreview else { refreshDeviceStatus(); return }
        if !stopped { for runtime in runtimes.values { runtime.refresh() } }
        setMappingStatus(selectedRuntime?.mappingStatus ?? "请添加遥控器；预设已保留")
        refreshDeviceStatus()
    }
    func setMappingStatus(_ value: String) {
        mappingLabel.stringValue = "映射：" + value
        serviceBadge.stringValue = stopped ? "服务已暂停" : "后台运行中"
        serviceBadge.textColor = stopped ? .secondaryLabelColor : .systemGreen
        if value != lastMappingStatus { lastMappingStatus = value; log(mappingLabel.stringValue) }
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    func log(_ text: String) {
        let line: String
        do { guard let written = try diagnostics?.append(text) else { return }; line = written }
        catch { outputLabel.stringValue = "日志保存失败：" + error.localizedDescription; return }
        logView.textStorage?.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor]))
        if logView.string.count > 100_000 { logView.textStorage?.deleteCharacters(in: NSRange(location: 0, length: 30_000)) }
        logView.scrollToEndOfDocument(nil)
    }
    @objc func permissions() {
        guard !isPreview else { refreshDeviceStatus(); return }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func showCalibration() { if !isPreview { calibration.show() } }
    @objc func keyPermissions() {
        guard !isPreview else { refreshDeviceStatus(); return }
        _ = CGRequestPostEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refreshMappings()
    }
    @objc func audioEnabledChanged() {
        guard !isPreview else { refreshDeviceStatus(); return }
        let enabled = audioToggle.state == .on
        UserDefaults.standard.set(enabled,forKey:"remoteMicEnabled")
        for runtime in runtimes.values { runtime.microphoneEnabled = enabled }
        if !enabled { systemMic.stop() }
        systemMic.refresh(); refreshDeviceStatus()
    }
    @objc func gainChanged() {
        guard !isPreview else { return }
        systemMic.gainDB = gainSlider.doubleValue
        UserDefaults.standard.set(gainSlider.doubleValue, forKey: "remoteMicGainDB")
        gainLabel.stringValue = "音量增强：\(Int(gainSlider.doubleValue)) dB"
    }
    @objc func installMicrophone() {
        guard !isPreview else { systemMicLabel.stringValue = "演示：正式安装时由系统安装器请求管理员确认。"; return }
        guard let package = Bundle.main.url(forResource: "安装遥控器麦克风", withExtension: "pkg") else { log("麦克风安装包尚未准备好。"); return }
        NSWorkspace.shared.open(package)
    }
    @objc func selectSystemMicrophone() {
        if !isPreview, systemMic.isDefault { systemMic.refresh(); return }
        let alert = NSAlert(); alert.messageText = "将遥控器麦克风设为系统默认？"
        alert.informativeText = "豆包等跟随系统输入的应用将使用小米遥控器收音。其他跟随系统输入的应用也会切换；已单独指定麦克风的应用继续使用自己的选择。以后可点击“恢复原麦克风”撤回。"
        alert.addButton(withTitle:"设为系统默认"); alert.addButton(withTitle:"保持当前设置")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !isPreview else { systemMicLabel.stringValue = "界面预览 · 系统默认麦克风未更改"; return }
        do { try systemMic.selectAsDefault() }
        catch { systemMicLabel.stringValue = "系统麦克风：" + error.localizedDescription; log(error.localizedDescription) }
    }
    @objc func restoreSystemMicrophone() {
        guard !isPreview else { return }
        do { try systemMic.restoreDefault() } catch { log(error.localizedDescription) }
    }
    @objc func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }
    @objc func testChanged() {
        guard !isPreview, let runtime = selectedRuntime, physicalKeys.isEmpty, !stopped else { testToggle.state = .off; return }
        runtime.ble.testingEnabled = testToggle.state == .on
        log(runtime.ble.testingEnabled ? "已开启所选设备原声录音保存。" : "原声录音保存已关闭。")
    }
    @objc func restart() {
        guard !isPreview else { refreshDeviceStatus(); return }
        recorder.cancel(); calibration.stop()
        guard reloadSavedMappings() else { return }
        for runtime in runtimes.values { runtime.stop() }
        do { try restoreMappingJournals() } catch { stopped = true; log(error.localizedDescription); return }
        emitter.recover(); systemMic.stop(); stopped = false; testToggle.state = .off
        for runtime in runtimes.values { runtime.ble.testingEnabled = false; runtime.start() }
        refreshMappings()
    }
    @objc func stopTest() {
        guard !isPreview else { return }
        recorder.cancel(); calibration.stop(); stopped = true; testToggle.state = .off
        for runtime in runtimes.values { runtime.ble.testingEnabled = false; runtime.stop() }
        emitter.stop(); systemMic.stop(); discovery.stop()
        refreshMappings()
    }
    @objc func playLatest() {
        guard let latestRecording else { log("还没有收到并保存真实音频。"); return }
        NSWorkspace.shared.open(latestRecording)
    }
    @objc func showLogs() { NSWorkspace.shared.open(output) }
    @objc func showLicense() {
        if let license = Bundle.main.url(forResource: "THIRD_PARTY", withExtension: "md") { NSWorkspace.shared.open(license) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        recorder.cancel("窗口已收起，录入已取消，原设置保留。")
        calibration.stop()
        sender.orderOut(nil)
        log("设置窗口已收起，遥控器映射继续运行；可从菜单栏“遥伴”打开设置或退出。")
        return false
    }
    func windowDidResignKey(_ notification: Notification) { recorder.cancel("窗口已切换，录入已取消。"); refreshPrivacyStatus() }
    func applicationDidResignActive(_ notification: Notification) { recorder.cancel("应用已切换，录入已取消。"); calibration.stop(); refreshPrivacyStatus() }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard hasUnsavedPresetDraft else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "保存当前预设修改？"
        alert.informativeText = "当前清空草稿尚未保存。"
        alert.addButton(withTitle:"保存并退出"); alert.addButton(withTitle:"放弃并退出"); alert.addButton(withTitle:"返回")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveCurrentProfile(); return hasUnsavedPresetDraft ? .terminateCancel : .terminateNow
        case .alertSecondButtonReturn:
            discardPresetDraft(); return .terminateNow
        default: return .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        guard !secondaryInstance, !isPreview else { return }
        log("收到退出请求，正在释放按键并恢复原键。")
        recorder.cancel()
        calibration.stop()
        poll?.invalidate(); actionTimer?.invalidate()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        for runtime in runtimes.values { runtime.stop() }
        emitter.stop(); discovery.stop(); systemMic.stop()
        do { try mapper?.restore(); log("原键已恢复，程序正常退出。") } catch { log("退出恢复失败，恢复记录已保留：\(error.localizedDescription)") }
        diagnostics = nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let lab = LabApp()
app.delegate = lab
app.run()
