// Xiaomi Remote Lab — GPL-3.0.
import AppKit

private final class SettingsBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect:NSRect) { NSColor.windowBackgroundColor.setFill(); NSBezierPath.fill(dirtyRect) }
}

private final class SettingsCard: NSView {
    override init(frame: NSRect) { super.init(frame:frame); wantsLayer = true; layer?.cornerRadius = 16; updateColor() }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
    private func updateColor() { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor } }
}

private final class MappingRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        LabApp.accent.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:2,dy:1),xRadius:8,yRadius:8).fill()
    }
}

extension LabApp {
    static var accent: NSColor { NSColor(srgbRed:0.93, green:0.47, blue:0.27, alpha:1) }
    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString:text)
        view.font = .systemFont(ofSize:size, weight:weight)
        view.textColor = secondary ? .secondaryLabelColor : .labelColor
        return view
    }
    func vertical(_ views: [NSView], spacing: CGFloat = 14) -> NSStackView {
        let stack = NSStackView(views:views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    func horizontal(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views:views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        return stack
    }
    func card(_ views: [NSView]) -> NSView {
        let view = SettingsCard(frame:.zero), stack = vertical(views)
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20), stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),
            stack.topAnchor.constraint(equalTo:view.topAnchor,constant:20), stack.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-20)])
        for row in views where row is NSStackView { row.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        return view
    }
    func page(_ views: [NSView], fill: Bool = false) -> NSView {
        let body = NSView(), stack = vertical(views, spacing:16)
        stack.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:body.topAnchor), stack.leadingAnchor.constraint(equalTo:body.leadingAnchor), stack.trailingAnchor.constraint(equalTo:body.trailingAnchor), fill ? stack.bottomAnchor.constraint(equalTo:body.bottomAnchor) : stack.bottomAnchor.constraint(lessThanOrEqualTo:body.bottomAnchor)])
        for view in views { view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        return body
    }
    func prepareTable(_ view: NSTableView) -> NSScrollView {
        for (id,title,width,minimum) in [("remote","遥控器按键",CGFloat(155),CGFloat(110)),("trigger","操作方式",175,145),("binding","点击／短按映射",300,215),("longBinding","长按映射",300,215)] {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = minimum; column.resizingMask = .autoresizingMask
            view.addTableColumn(column)
        }
        view.delegate = self; view.dataSource = self; view.rowHeight = 48; view.intercellSpacing = NSSize(width:0,height:2)
        view.style = .fullWidth; view.backgroundColor = .controlBackgroundColor
        view.gridStyleMask = .solidHorizontalGridLineMask; view.gridColor = .separatorColor
        view.target = self; view.doubleAction = nil; view.action = #selector(selectMappingCell)
        view.allowsEmptySelection = false; view.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200).isActive = true
        return scroll
    }
    func spring() -> NSView {
        let v = NSView(); v.setContentHuggingPriority(.defaultLow,for:.horizontal); return v
    }
    func symbol(_ name: String, size: CGFloat) -> NSImageView {
        let v = NSImageView(image:NSImage(systemSymbolName:name,accessibilityDescription:nil)!)
        v.symbolConfiguration = .init(pointSize:size,weight:.regular); return v
    }
    func remotePhoto() -> NSView {
        let original = NSImage(named:"Xiaomi2Pro-illustration") ?? NSImage()
        // Display only the device area; the distributed PNG remains unmodified.
        let image = NSImage(size:NSSize(width:365,height:1195),flipped:false) { rect in
            original.draw(in:rect,from:NSRect(x:330,y:190,width:365,height:1195),operation:.sourceOver,fraction:1)
            return true
        }
        let view = NSImageView(image:image); view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("小米蓝牙遥控器 2 Pro · 设备示意图")
        view.toolTip = "AI 生成的设备示意图，非官方产品照片"
        view.widthAnchor.constraint(equalToConstant:48).isActive = true
        view.heightAnchor.constraint(equalToConstant:64).isActive = true
        return vertical([view,label("设备示意图",size:9,secondary:true)],spacing:3)
    }
    func makeWindow() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1220,height:840), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title = "遥伴"; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width:1040,height:740); window.delegate = self
        window.contentView = SettingsBackground(frame:window.contentView!.frame)
        let root = window.contentView!
        root.wantsLayer = false
        let sidebar = NSVisualEffectView(); sidebar.material = .sidebar; sidebar.blendingMode = .withinWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sidebar)
        let main = vertical([],spacing:14); main.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(main)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo:root.leadingAnchor), sidebar.topAnchor.constraint(equalTo:root.topAnchor), sidebar.bottomAnchor.constraint(equalTo:root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant:208),
            main.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:28), main.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-28), main.topAnchor.constraint(equalTo:root.topAnchor,constant:24), main.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-22)])
        let icon = NSImageView(image:NSImage(named:"BrandMark") ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown; icon.widthAnchor.constraint(equalToConstant:56).isActive = true; icon.heightAnchor.constraint(equalToConstant:56).isActive = true
        let brand = vertical([horizontal([icon,label("遥伴",size:25,weight:.semibold)],spacing:6)],spacing:5)
        let navigation = vertical([brand],spacing:10); navigation.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(navigation)
        let gap = NSView(); gap.heightAnchor.constraint(equalToConstant:24).isActive = true; navigation.addArrangedSubview(gap)
        for item in [("按键","square.grid.2x2",0),("触控","hand.draw",5),("语音","mic",1),("遥控器","appletvremote.gen1",4),("设置","gearshape",2)] {
            let b = button(item.0,#selector(navigateSettings(_:))); b.tag = item.2; b.image = NSImage(systemSymbolName:item.1,accessibilityDescription:nil)
            b.imagePosition = .imageLeading; b.imageHugsTitle = false; b.alignment = .left; b.isBordered = false
            b.font = .systemFont(ofSize:16,weight:.medium); b.wantsLayer = true; b.layer?.cornerRadius = 12
            b.heightAnchor.constraint(equalToConstant:50).isActive = true; b.widthAnchor.constraint(equalToConstant:172).isActive = true
            navButtons.append(b); navigation.addArrangedSubview(b)
        }
        serviceBadge.font = .systemFont(ofSize:13,weight:.medium); serviceBadge.stringValue = "后台运行中"; serviceBadge.textColor = .systemGreen
        let footer = vertical([horizontal([symbol("waveform",size:18),serviceBadge]),label("遥伴 · v" + (Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发版"),size:11,secondary:true)],spacing:12)
        footer.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(footer)
        NSLayoutConstraint.activate([navigation.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:18),navigation.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:28),footer.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:26),footer.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor,constant:-26)])
        currentModeLabel.font = .systemFont(ofSize:13,weight:.medium); currentModeLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        currentModeLabel.lineBreakMode = .byTruncatingTail; currentModeLabel.widthAnchor.constraint(lessThanOrEqualToConstant:190).isActive = true
        profilePopup.target = self; profilePopup.action = #selector(profileSelected); profilePopup.widthAnchor.constraint(equalToConstant:150).isActive = true
        profilePopup.font = .systemFont(ofSize:14)
        let save = saveProfileButton; save.target = self; save.action = #selector(saveCurrentProfile); save.isBordered = false; save.wantsLayer = true; save.layer?.backgroundColor = Self.accent.cgColor; save.layer?.cornerRadius = 10
        save.attributedTitle = NSAttributedString(string:"保存",attributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:14,weight:.semibold)])
        save.widthAnchor.constraint(equalToConstant:82).isActive = true; save.heightAnchor.constraint(equalToConstant:38).isActive = true
        loadProfileButton.target = self; loadProfileButton.action = #selector(loadSelectedProfile)
        deleteProfileButton.target = self; deleteProfileButton.action = #selector(deleteProfile)
        modeMoreButton.addItem(withTitle:"更多"); modeMoreButton.menu?.autoenablesItems = false
        for (title,action) in [("另存为…",#selector(saveNewProfile)),("删除预设…",#selector(deleteProfile)),("重命名…",#selector(renameProfile)),("设为启动预设",#selector(useAsDefault))] {
            modeMoreButton.addItem(withTitle:title); modeMoreButton.lastItem?.target = self; modeMoreButton.lastItem?.action = action
        }
        modeMoreButton.menu?.addItem(.separator())
        modeMoreButton.addItem(withTitle:"清空当前预设")
        modeMoreButton.lastItem?.target = self; modeMoreButton.lastItem?.action = #selector(clearCurrentPreset)
        modeMoreButton.addItem(withTitle:"放弃未保存修改")
        modeMoreButton.lastItem?.target = self; modeMoreButton.lastItem?.action = #selector(discardCurrentPreset)
        editingDevicePopup.target = self; editingDevicePopup.action = #selector(editingDeviceSelected(_:))
        editingDevicePopup.widthAnchor.constraint(equalToConstant:180).isActive = true
        let modeBar = horizontal([label("遥控器",size:13,secondary:true),editingDevicePopup,currentModeLabel,profilePopup,loadProfileButton,save,modeMoreButton,spring()],spacing:8)
        profileSelectionLabel.font = .systemFont(ofSize:12)
        let modeControls = vertical([modeBar,profileSelectionLabel],spacing:8)
        main.addArrangedSubview(modeControls); modeControls.widthAnchor.constraint(equalTo:main.widthAnchor).isActive = true
        modeBar.widthAnchor.constraint(equalTo:modeControls.widthAnchor).isActive = true
        profileSelectionLabel.widthAnchor.constraint(equalTo:modeControls.widthAnchor).isActive = true
        let deviceIcon = remotePhoto()
        devicePhotoView = deviceIcon
        deviceTitle.font = .systemFont(ofSize:19,weight:.semibold); deviceTitle.lineBreakMode = .byTruncatingTail
        deviceConnection.font = .systemFont(ofSize:14,weight:.medium)
        deviceChannels.font = .systemFont(ofSize:13); deviceChannels.textColor = .secondaryLabelColor
        batteryLabel.font = .systemFont(ofSize:13); batteryLabel.textColor = .secondaryLabelColor
        let batteryIcon = symbol("battery.100percent",size:17); batteryIconView = batteryIcon
        let batteryStatus = horizontal([batteryIcon,batteryLabel],spacing:6)
        let deviceInfo = vertical([horizontal([deviceTitle,deviceConnection],spacing:18),horizontal([deviceChannels,batteryStatus],spacing:20)],spacing:10)
        deviceHint.font = .systemFont(ofSize:12); deviceHint.textColor = .secondaryLabelColor
        let banner = card([horizontal([deviceIcon,deviceInfo,spring()],spacing:20),deviceHint])
        main.addArrangedSubview(banner); banner.widthAnchor.constraint(equalTo:main.widthAnchor).isActive = true
        pageTitle.font = .systemFont(ofSize:24,weight:.semibold)
        main.addArrangedSubview(pageTitle)
        main.addArrangedSubview(pageHost); pageHost.widthAnchor.constraint(equalTo:main.widthAnchor).isActive = true
        pageHost.setContentHuggingPriority(.defaultLow,for:.vertical); pageHost.heightAnchor.constraint(greaterThanOrEqualToConstant:380).isActive = true
        let keyList = prepareTable(table)
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        recordingLabel.textColor = .secondaryLabelColor; recordingLabel.font = .systemFont(ofSize:12)
        recordingLabel.maximumNumberOfLines = 2; recordingLabel.lineBreakMode = .byWordWrapping
        cancelRecordingButton.target = self; cancelRecordingButton.action = #selector(cancelRecording); cancelRecordingButton.isHidden = true
        longDelayPopup.target = self; longDelayPopup.action = #selector(longDelayChanged)
        longDelayPopup.widthAnchor.constraint(equalToConstant:92).isActive = true
        originalBindingButton.target = self; originalBindingButton.action = #selector(originalBinding)
        originalBindingButton.bezelStyle = .rounded
        originalBindingButton.isHidden = binding?.model == .apple
        let timing = horizontal([label("长按判定",size:12,secondary:true),longDelayPopup,label("连发等待 0.4 秒",size:12,secondary:true),spring()],spacing:10)
        let keyControls = vertical([keyList,timing,recordingLabel])
        keyControls.identifier = NSUserInterfaceItemIdentifier("keyMappingControls")
        for view in [keyList,timing,recordingLabel] { view.widthAnchor.constraint(equalTo:keyControls.widthAnchor).isActive = true }
        let emptyKeyState = card([
            label("还没有遥控器",size:20,weight:.semibold),
            label("添加第一只遥控器后，即可设置每个按键的映射和长按操作。",size:14,secondary:true),
            button("添加遥控器…",#selector(bindRemote))
        ])
        emptyKeyState.identifier = NSUserInterfaceItemIdentifier("keyMappingEmptyState")
        let keyPage = page([keyControls,emptyKeyState],fill:true)
        let touchPage = page([makeTouchControls()],fill:true)
        audioToggle.state = UserDefaults.standard.object(forKey:"remoteMicEnabled") as? Bool == false ? .off : .on
        audioToggle.target = self; audioToggle.action = #selector(audioEnabledChanged)
        let gain = UserDefaults.standard.object(forKey:"remoteMicGainDB") as? Double ?? 12
        gainSlider.doubleValue = gain.isFinite ? min(24,max(0,gain)) : 12; gainSlider.target = self; gainSlider.action = #selector(gainChanged)
        gainSlider.widthAnchor.constraint(equalToConstant:220).isActive = true; gainLabel.stringValue = "音量增强：\(Int(gainSlider.doubleValue)) dB"
        let micPage = page([card([horizontal([label("遥控器麦克风",size:18,weight:.semibold),spring(),audioToggle]),bleLabel,levelLabel]),card([label("输入音量",size:16,weight:.semibold),horizontal([gainLabel,gainSlider])]),card([label("系统输入",size:16,weight:.semibold),systemMicLabel,horizontal([button("设为系统输入",#selector(selectSystemMicrophone)),button("恢复原输入",#selector(restoreSystemMicrophone)),button("声音设置…",#selector(openSoundSettings))])])])
        loginToggle.target = self; loginToggle.action = #selector(loginChanged)
        let generalPage = page([card([label("后台运行",size:18,weight:.semibold),loginToggle,loginLabel]),card([label("系统与隐私",size:18,weight:.semibold),privacyLabel,horizontal([button("系统检查…",#selector(showSystemCheck)),button("管理登录项…",#selector(openLoginSettings)),button("开源许可…",#selector(showLicense))])])])
        testToggle.target = self; testToggle.action = #selector(testChanged)
        let logs = NSScrollView(); logs.hasVerticalScroller = true; logs.borderType = .noBorder
        logView.isEditable = false; logView.font = .monospacedSystemFont(ofSize:11,weight:.regular); logView.textContainerInset = NSSize(width:10,height:10)
        logView.autoresizingMask = [.width]; logView.isVerticallyResizable = true; logView.isHorizontallyResizable = false; logView.textContainer?.widthTracksTextView = true
        logs.documentView = logView; logs.heightAnchor.constraint(equalToConstant:115).isActive = true
        let advancedDetails = page([mappingLabel,hidLabel,keyLabel,outputLabel,testToggle,horizontal([button("试听录音",#selector(playLatest)),button("清理录音…",#selector(clearRecordings)),button("查看记录",#selector(showLogs)),button("对齐键位",#selector(showCalibration))]),logs])
        let advanced = DisclosureSection(title:"高级诊断",content:advancedDetails)
        let advancedPage = page([makePermissionsCard(),card([horizontal([label("输入服务",size:17,weight:.semibold),spring(),button("重新检测",#selector(restart)),button("停用",#selector(stopTest))]),horizontal([button("安装麦克风组件…",#selector(installMicrophone)),button("声音设置…",#selector(openSoundSettings))])]),advanced])
        pages = [keyPage,micPage,generalPage,advancedPage,makeDevicePage(),touchPage]
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false; pageHost.addSubview(page)
            pageConstraints.append([page.leadingAnchor.constraint(equalTo:pageHost.leadingAnchor),page.trailingAnchor.constraint(equalTo:pageHost.trailingAnchor),page.topAnchor.constraint(equalTo:pageHost.topAnchor),page.bottomAnchor.constraint(equalTo:pageHost.bottomAnchor)])
        }
        refreshKeyPageControls()
        selectPage(0)
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle:"退出遥伴",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        window.center()
    }
    @objc func navigateSettings(_ sender: NSButton) { recorder.cancel(); selectPage(sender.tag) }
    func selectPage(_ index: Int) {
        if index == 4 && !isPreview { discovery.prepareDiscovery() }
        guard pages.indices.contains(index) else { return }
        let titles = ["按键","语音","设置","系统检查","遥控器","触控"]
        pageTitle.stringValue = titles[index]
        for constraints in pageConstraints { NSLayoutConstraint.deactivate(constraints) }
        for i in pages.indices { pages[i].isHidden = i != index }
        NSLayoutConstraint.activate(pageConstraints[index])
        let selected = index == 3 ? 2 : index
        for b in navButtons { b.contentTintColor = b.tag == selected ? Self.accent : .labelColor; b.layer?.backgroundColor = (b.tag == selected ? Self.accent.withAlphaComponent(0.11) : NSColor.clear).cgColor }
    }
    func settingsSubview(withIdentifier identifier: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == identifier { return view }
        for child in view.subviews {
            if let match = settingsSubview(withIdentifier:identifier,in:child) { return match }
        }
        return nil
    }
    func refreshKeyPageControls() {
        let hasDevice = selectedDevice != nil
        settingsSubview(withIdentifier:NSUserInterfaceItemIdentifier("keyMappingControls"),in:pageHost)?.isHidden = !hasDevice
        settingsSubview(withIdentifier:NSUserInterfaceItemIdentifier("keyMappingEmptyState"),in:pageHost)?.isHidden = hasDevice
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { MappingRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let column = tableColumn?.identifier.rawValue ?? "", source = rows[row]
        let mode = configuration.trigger(for:source)
        if column == "trigger" {
            let popup = NSPopUpButton(frame:.zero,pullsDown:false)
            for choice in ActionTrigger.selectable { popup.addItem(withTitle:choice.title); popup.lastItem?.representedObject = choice.rawValue }
            popup.selectItem(at:ActionTrigger.selectable.firstIndex(of:mode) ?? 0)
            popup.tag = Int(source); popup.target = self; popup.action = #selector(singleTriggerChanged(_:)); popup.font = .systemFont(ofSize:13)
            popup.setAccessibilityLabel("\(sourceName(source)) 操作方式")
            popup.toolTip = "普通：按下执行；长按连发：按下执行后继续重复；短按／长按：只执行其中一套映射。"
            let cell = NSTableCellView(); popup.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(popup)
            NSLayoutConstraint.activate([popup.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:8),popup.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-12),popup.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        let isLong = column == "longBinding"
        let editable = column == "binding" || (isLong && mode == .shortLong)
        if editable {
            let popup = NSPopUpButton(frame:.zero,pullsDown:false)
            let keys = isLong ? configuration.longBindings[source] : configuration.bindings[source]
            let capturing = recordingSource == source && recordingLongPress == isLong
            let emptyMapping = !capturing && (keys?.isEmpty == true || (isLong && keys == nil))
            if emptyMapping {
                popup.addItem(withTitle:"无映射"); popup.lastItem?.representedObject = "none"
            } else {
                popup.addItem(withTitle:capturing ? recordingPreview : keys.map(KeyboardKey.compactDescription) ?? (isLong ? "无映射" : "保持原键"))
                popup.lastItem?.representedObject = "current"
                popup.addItem(withTitle:"无映射"); popup.lastItem?.representedObject = "none"
            }
            popup.addItem(withTitle:"创建映射…"); popup.lastItem?.representedObject = "create"
            popup.tag = Int(source) + (isLong ? 0x10000 : 0); popup.target = self; popup.action = #selector(mappingSelected(_:))
            popup.font = .systemFont(ofSize:13); popup.setAccessibilityLabel("\(sourceName(source)) \(isLong ? "长按" : "短按")映射")
            let cell = NSTableCellView(); popup.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(popup)
            NSLayoutConstraint.activate([popup.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:8),popup.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-12),popup.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        let recording = editable && recordingSource == source && recordingLongPress == isLong
        let text: String
        if column == "remote" { text = sourceName(source) }
        else if recording { text = recordingPreview }
        else if isLong {
            text = mode == .shortLong ? configuration.longBindings[source].map(KeyboardKey.compactDescription) ?? "无映射" : mode == .repeating ? "重复左侧映射" : "—"
        } else { text = configuration.bindings[source].map(KeyboardKey.compactDescription) ?? "保持原键" }
        let cell = NSTableCellView(), value = NSTextField(labelWithString:text)
        value.font = .systemFont(ofSize:14,weight:column == "remote" ? .medium : .regular)
        value.textColor = recording ? Self.accent : (isLong && (mode != .shortLong || configuration.longBindings[source] == nil)) ? .secondaryLabelColor : .labelColor
        value.lineBreakMode = .byTruncatingTail
        let keys = isLong ? configuration.longBindings[source] : configuration.bindings[source]
        value.toolTip = editable ? "\(keys.map(KeyboardKey.describe) ?? text)" : text
        value.setAccessibilityLabel("\(sourceName(source)) \(isLong ? "长按映射" : column == "remote" ? "按键" : "点击／短按映射")")
        value.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(value); cell.textField = value
        var leading: CGFloat = 12
        if column == "remote" {
            let symbols: [UInt16:String] = [0x3E:"mic",0x28:"record.circle",0xF1:"arrow.left",0x80:"speaker.plus",0x81:"speaker.minus",0x65:"list.bullet",0x52:"arrow.up",0x51:"arrow.down",0x50:"arrow.left",0x4F:"arrow.right",0x4A:"house",0x35:"tv",0x66:"power"]
            let icon = symbol(source == RemoteButtonLayout.playPause ? "playpause" : source == RemoteButtonLayout.mute ? "speaker.slash" : symbols[source] ?? "circle",size:17)
            icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:12),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:22)])
            leading = 44
        }
        if editable {
            value.isBezeled = true; value.bezelStyle = .roundedBezel; value.drawsBackground = true
            value.backgroundColor = recording ? Self.accent.withAlphaComponent(0.08) : NSColor(srgbRed:0.99,green:0.985,blue:0.98,alpha:1)
        }
        NSLayoutConstraint.activate([value.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:leading),value.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-12),value.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        if editable { value.heightAnchor.constraint(equalToConstant:30).isActive = true }
        return cell
    }
}
