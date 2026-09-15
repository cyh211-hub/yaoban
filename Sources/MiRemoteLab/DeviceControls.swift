import AppKit
import IOKit.hid

private final class DeviceListDocument: NSView {
    override var isFlipped: Bool { true }
}

extension LabApp {
    func refreshDeviceStatus() {
        refreshKeyPageControls()
        refreshTouchControls()
        for button in navButtons where button.tag == 5 { button.isHidden = binding?.model != .apple }
        refreshSetupStatus(); refreshPrivacyStatus()
        let runtime = selectedRuntime
        let present = runtime?.connectionForDisplay == true
        var state = RemoteDeviceStatus.resolve(bound:binding != nil,stopped:stopped || selectedDevice?.enabled == false,present:present,
            radio:isPreview || runtime?.isApple == true ? .ready : runtime?.ble.radioAvailability ?? discovery.radioAvailability,
            inputAllowed:isPreview || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
            outputAllowed:isPreview || CGPreflightPostEventAccess(),mappingReady:runtime?.mappingStatus.hasPrefix("映射已就绪") == true,
            microphoneEnabled:audioToggle.state == .on,voiceReady:runtime?.voiceReady == true,driverAvailable:isPreview || systemMic.available,
            outputFailure:isPreview ? nil : emitter.failure,pairingChanged:runtime?.ble.needsBindingSelection == true,hasBinding:binding?.isBound == true)
        if binding?.isBound == true && (runtime?.isApple == true || binding?.model == .apple) {
            let hint = state.connection == .disconnected ? "系统蓝牙断开后，先轻按方向键；若仍未连接，可按住返回〈和音量＋约 5 秒恢复连接，保留原配对与键位。" : "请在系统检查中确认按键权限和语音组件状态。"
            let microphone = audioToggle.state == .on ? (runtime?.voiceStatus ?? "等待连接") : "已关闭"
            state = RemoteDeviceStatus(connection:state.connection,keyboard:state.keyboard,microphone:microphone,hint:hint)
        }
        devicePhotoView?.isHidden = binding == nil || binding?.model == .apple
        deviceTitle.stringValue = selectedDevice.map { displayName(for:$0) } ?? "添加你的第一只遥控器"
        deviceConnection.stringValue = isPreview ? "● 界面演示" : "● " + state.connection.rawValue
        deviceConnection.textColor = state.connection == .connected ? .systemGreen : .systemRed
        let reading = runtime?.battery ?? RemoteBatteryReading()
        let connected = !stopped && present
        let percent = reading.current(connected:connected)
        batteryLabel.stringValue = percent == nil ? "电量暂未读取" : reading.title(connected:connected)
        batteryLabel.textColor = percent.map { $0 <= 20 } == true ? .systemOrange : .secondaryLabelColor
        batteryIconView?.image = NSImage(systemSymbolName:RemoteBatteryReading.symbol(for:percent),accessibilityDescription:"遥控器电量")
        deviceChannels.stringValue = isPreview ? "演示设备 · 不连接硬件" : "按键：\(state.keyboard)  ·  麦克风：\(state.microphone)"
        deviceHint.isHidden = state.connection == .connected
        deviceHint.stringValue = isPreview ? "隔离演示 · 未连接硬件，未更改当前运行版的设置。" : state.hint
        hidLabel.stringValue = "按键：" + (runtime?.keyStatus ?? state.keyboard)
        bleLabel.stringValue = "遥控器音频：" + (runtime?.voiceStatus ?? state.microphone)
        mappingLabel.stringValue = "映射：" + (runtime?.mappingStatus ?? (binding == nil ? "请添加遥控器" : "未绑定设备"))
        serviceBadge.stringValue = isPreview ? "界面预览" : stopped ? "服务已暂停" : (selectedRuntime?.running == true ? "当前设备运行中" : "当前设备未启用")
        serviceBadge.textColor = !stopped && selectedRuntime?.running == true ? .systemGreen : .systemRed
        if state != lastDeviceStatus { lastDeviceStatus = state; makeStatusMenu() }
        refreshDeviceList()
    }
    func refreshPrivacyStatus() {
        privacyLabel.stringValue = isPreview ? "界面预览 · 未启用键鼠监听"
            : recorder.isActive ? "正在录入快捷键 · 完成、取消或离开窗口后停止"
            : calibration.isActive ? "正在对齐修饰键 · 完成或离开窗口后停止"
            : emitter.isObserving ? "正在协调遥控器动作 · 松开后结束，释放核对最长 0.7 秒"
            : "全局键鼠监听已关闭 · 遥控器输入服务继续待命"
        privacyLabel.font = .systemFont(ofSize:13,weight:.medium)
        privacyLabel.textColor = .secondaryLabelColor
    }
    func refreshSetupStatus() {
        refreshPermissionRows()
        let readAllowed = isPreview || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let sendAllowed = isPreview || CGPreflightPostEventAccess()
        setupPermissionLabel.stringValue = "输入监控：\(readAllowed ? "已允许" : "待开启")    辅助功能：\(sendAllowed ? "已允许" : "待开启")"
        setupPermissionLabel.font = .systemFont(ofSize:12); setupPermissionLabel.textColor = .secondaryLabelColor
    }
    func makeDevicePage() -> NSView {
        deviceList.orientation = .vertical; deviceList.alignment = .leading; deviceList.spacing = 16
        let listCard = card([horizontal([label("我的遥控器",size:19,weight:.semibold),spring(),button("添加…",#selector(bindRemote))]),deviceList])
        let content = vertical([listCard,
            card([horizontal([button("系统蓝牙",#selector(openBluetoothSettings)),button("系统检查",#selector(showSystemCheck)),button("重新检测",#selector(restart))])])],spacing:16)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let document = DeviceListDocument(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        content.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo:document.topAnchor),content.bottomAnchor.constraint(equalTo:document.bottomAnchor),
            content.leadingAnchor.constraint(equalTo:document.leadingAnchor),content.trailingAnchor.constraint(equalTo:document.trailingAnchor)])
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true }
        return scroll
    }
    @objc func openBluetoothSettings() {
        guard !isPreview else { recordingLabel.stringValue = "界面预览不更改系统蓝牙。"; return }
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }
    @objc func openBluetoothPrivacy() {
        guard !isPreview else { return }
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
    }
    @objc func showKeyPage() { recorder.cancel(); selectPage(0) }
    @objc func showMicrophonePage() { recorder.cancel(); selectPage(1) }
    @objc func showDevicePage() { recorder.cancel(); selectPage(4) }
    @objc func showAdvancedPage() { recorder.cancel(); selectPage(3) }
}
