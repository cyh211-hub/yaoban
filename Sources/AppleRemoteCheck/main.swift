// Yaoban — GPL-3.0. An explicitly started, time-bounded Apple hardware check.
import AppKit
import IOKit.hid
import CryptoKit

final class AppleHardwareCheck {
    var changed: () -> Void = {}
    private(set) var active = false
    private(set) var lines: [String] = []
    private(set) var buttonRows = Set<String>()
    private(set) var interfaces: [UInt64: IOHIDDevice] = [:]
    private(set) var batteryText = "未知（尚未读取）"
    private var manager: IOHIDManager?
    private var physical: [UInt64: String] = [:]
    private var states: [String: AppleButtonState] = [:]
    private var reportShapes = Set<String>()
    private var elementShapes = Set<String>()
    private var rawButtons: [AppleButtonState.Element: Int] = [:]
    private var observedBatteries: [UInt64: Int] = [:]
    private var batteryHistory: [[String:Any]] = []
    private var deadline: Timer?
    private var started = ProcessInfo.processInfo.systemUptime
    private(set) var resultURL: URL
    // Identity tokens are session salted, to group sibling interfaces without writing serials.
    private let salt = UUID().uuidString

    init(directory: URL) { resultURL = directory.appendingPathComponent("apple-hardware-check.json") }

    var permissionGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    func requestPermission() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    private func emit(_ line: String) {
        if lines.count < 2400 {
            lines.append(String(format:"%.3f ",ProcessInfo.processInfo.systemUptime - started) + line)
        }
        changed()
    }
    private func registryID(_ device: IOHIDDevice) -> UInt64? {
        var value: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &value) == KERN_SUCCESS,
              value != 0 else { return nil }
        return value
    }
    private func number(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
    private func isTarget(_ device: IOHIDDevice) -> Bool {
        AppleButtonInput.matches(vendor:number(device,kIOHIDVendorIDKey) ?? -1,
            product:number(device,kIOHIDProductIDKey) ?? -1,
            transport:IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String)
    }

    func start() {
        guard !active else { return }
        guard permissionGranted else { emit("等待输入监控权限；授权后再点开始检查。"); return }
        do { try PrivateFiles.ensureDirectory(resultURL.deletingLastPathComponent()) }
        catch { emit("无法准备检查记录：\(error.localizedDescription)"); return }
        lines = []; buttonRows = []; reportShapes = []; elementShapes = []; observedBatteries = [:]; rawButtons = [:]; batteryHistory = []
        batteryText = "未知（设备尚未上报）"; started = ProcessInfo.processInfo.systemUptime
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        manager = m; active = true
        IOHIDManagerSetDeviceMatchingMultiple(m, [
            [kIOHIDVendorIDKey:AppleButtonInput.vendorID,kIOHIDProductIDKey:AppleButtonInput.productID]
        ] as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, result, _, device in
            guard let ctx, result == kIOReturnSuccess else { return }
            Unmanaged<AppleHardwareCheck>.fromOpaque(ctx).takeUnretainedValue().connected(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<AppleHardwareCheck>.fromOpaque(ctx).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, result, _, value in
            guard let ctx, result == kIOReturnSuccess else { return }
            Unmanaged<AppleHardwareCheck>.fromOpaque(ctx).takeUnretainedValue().received(value)
        }, context)
        IOHIDManagerRegisterInputReportCallback(m, { ctx, result, sender, _, reportID, _, length in
            guard let ctx, let sender, result == kIOReturnSuccess, length > 0, length <= 8192 else { return }
            let receiver = Unmanaged<AppleHardwareCheck>.fromOpaque(ctx).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            guard receiver.active, let id = receiver.registryID(device), receiver.interfaces[id] != nil else { return }
            let shape = "接口 \(id) 报告 \(reportID) 长度 \(length)"
            if receiver.reportShapes.count < 150 && receiver.reportShapes.insert(shape).inserted {
                receiver.emit("报告形状（不记录内容）：" + shape)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // Passive observation: no device seizure, feature/output reports or native-key remapping.
        let result = IOHIDManagerOpen(m, 0)
        guard result == kIOReturnSuccess else { stop(); emit("无法打开苹果设备监听：\(result)"); return }
        emit("开始 120 秒检查；只观察 USB-C Siri Remote 的输入，不发送键鼠或启用录音。")
        deadline = Timer(timeInterval:120,repeats:false) { [weak self] _ in self?.stop() }
        RunLoop.main.add(deadline!,forMode:.common)
    }

    private func connected(_ device: IOHIDDevice) {
        guard active, isTarget(device), let id = registryID(device), interfaces[id] == nil,
              interfaces.count < 64 else { return }
        interfaces[id] = device
        let serial = IOHIDDeviceGetProperty(device,kIOHIDSerialNumberKey as CFString) as? String
        let location = number(device,kIOHIDLocationIDKey)
        let identity: String
        if let serial, !serial.isEmpty { identity = "serial:" + serial }
        else if let location, location != 0 { identity = "location:\(location)" }
        else { identity = "interface:\(id)" }
        let token = SHA256.hash(data:Data((salt + identity).utf8)).prefix(8).map { String(format:"%02x",$0) }.joined()
        physical[id] = token
        emit("已连接：设备 \(token) 接口 \(id)，HID 004C:0315，页 \(number(device,kIOHIDPrimaryUsagePageKey) ?? -1) / 用法 \(number(device,kIOHIDPrimaryUsageKey) ?? -1)")
        if serial == nil && (location == nil || location == 0) { emit("此接口缺少可核对的物理身份，暂独立显示，不能用于自动绑定。") }
        // Read only published properties; absence is unknown, never a made-up battery estimate.
        updateBattery(device, id:id)
        if let elements = IOHIDDeviceCopyMatchingElements(device,nil,0) as? [IOHIDElement] {
            for e in elements.prefix(160) {
                emit("元素：接口 \(id) 类型 \(IOHIDElementGetType(e).rawValue) 页 \(IOHIDElementGetUsagePage(e)) 用法 \(IOHIDElementGetUsage(e)) 报告 \(IOHIDElementGetReportID(e)) 位宽 \(IOHIDElementGetReportSize(e)) 数量 \(IOHIDElementGetReportCount(e)) 范围 \(IOHIDElementGetLogicalMin(e))…\(IOHIDElementGetLogicalMax(e))")
            }
        }
    }
    private func updateBattery(_ device: IOHIDDevice, id: UInt64) {
        if let value = AppleButtonInput.battery(number(device,"BatteryPercent")) {
            if observedBatteries[id] != value && batteryHistory.count < 160 {
                batteryHistory.append(["at":ProcessInfo.processInfo.systemUptime-started,
                    "source":physical[id] ?? "unknown","percent":value])
                emit("电量属性：\(value)%（已保存实际读数）")
            }
            observedBatteries[id] = value
        }
        let values = Set(observedBatteries.values)
        batteryText = values.isEmpty ? "未知（设备尚未上报）" : values.sorted().map { "\($0)%" }.joined(separator:" / ")
    }
    private func publish(_ edges: [AppleButtonState.Edge], source: String) {
        for edge in edges {
            let stage = edge.pressed ? "按下" : "松开"
            buttonRows.insert(edge.button.rawValue + ":" + stage)
            emit("\(edge.button.title) · \(stage)（设备 \(source)）")
        }
    }
    private func received(_ value: IOHIDValue) {
        guard active else { return }
        let e = IOHIDValueGetElement(value), device = IOHIDElementGetDevice(e)
        guard let id = registryID(device), interfaces[id] != nil, let source = physical[id] else { return }
        let page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e)
        let type = IOHIDElementGetType(e)
        guard type == kIOHIDElementTypeInput_Button || type == kIOHIDElementTypeInput_Misc ||
                type == kIOHIDElementTypeInput_Axis || type == kIOHIDElementTypeInput_ScanCodes else { return }
        let shape = "接口 \(id) 页 \(page) 用法 \(usage) 报告 \(IOHIDElementGetReportID(e)) 长度 \(IOHIDValueGetLength(value))"
        if elementShapes.count < 200 && elementShapes.insert(shape).inserted {
            emit("输入形状：" + shape)
        }
        // Never interpret an array/audio blob as a scalar button. Unknown values stay metadata only.
        guard (1...8).contains(IOHIDValueGetLength(value)),
              (1...32).contains(IOHIDElementGetReportSize(e)),
              IOHIDElementGetReportCount(e) == 1,
              AppleButtonInput.decode(page:page,usage:usage,value:0) != nil else { return }
        let integer = IOHIDValueGetIntegerValue(value)
        let cookie = UInt32(IOHIDElementGetCookie(e))
        guard let (button, pressed) = AppleButtonInput.decode(page:page,usage:usage,value:integer) else { return }
        let rawKey = AppleButtonState.Element(interface:id,cookie:cookie)
        if rawButtons[rawKey] != integer {
            rawButtons[rawKey] = integer
            emit("原始按键：接口 \(id) 元素 \(cookie) \(button.title) 值 \(pressed ? 1 : 0)")
        }
        var state = states[source] ?? AppleButtonState()
        let edges = state.receive(interface:id,cookie:cookie,page:page,usage:usage,value:integer)
        states[source] = state
        publish(edges,source:source)
        updateBattery(device,id:id)
    }
    private func removed(_ device: IOHIDDevice) {
        guard let id = registryID(device), interfaces.removeValue(forKey:id) != nil else { return }
        observedBatteries[id] = nil
        rawButtons = rawButtons.filter { $0.key.interface != id }
        if let source = physical.removeValue(forKey:id), var state = states[source] {
            let cancelled = state.remove(interface:id)
            for edge in cancelled { emit("断线取消观察：\(edge.button.title)（非实际松开信号）") }
            states[source] = physical.values.contains(source) ? state : nil
        }
        updateBatteryTextAfterRemoval()
        emit("接口 \(id) 已断开；仍连接 \(interfaces.count) 个接口。")
    }
    private func updateBatteryTextAfterRemoval() {
        batteryText = observedBatteries.isEmpty ? "未知（未连接或未上报）" : Set(observedBatteries.values).sorted().map { "\($0)%" }.joined(separator:" / ")
    }
    func stop() {
        guard active || manager != nil else { return }
        active = false; deadline?.invalidate(); deadline = nil
        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager,nil,nil)
            IOHIDManagerRegisterInputReportCallback(manager,nil,nil)
            IOHIDManagerRegisterDeviceMatchingCallback(manager,nil,nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager,nil,nil)
            IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager,0)
        }
        manager = nil
        let heldAtStop = states.values.reduce(0) { $0 + $1.buttons.count }
        // Cancelled observation isn't evidence of a physical release.
        states.removeAll(); interfaces.removeAll(); physical.removeAll(); observedBatteries.removeAll(); rawButtons.removeAll()
        batteryText = "未知（检查已停止）"
        emit("检查已停止；取消 \(heldAtStop) 个仍按住的观察状态。")
        save()
    }
    func save() {
        let record: [String:Any] = ["formatVersion":1,"kind":"passive-apple-hid-check",
            "date":ISO8601DateFormatter().string(from:Date()),"active":active,
            "buttonEdgesObserved":buttonRows.sorted(),"lines":lines,"batteryReadings":batteryHistory,
            "nativeMappingVerified":false,"touchCursorVerified":false,"remoteMicrophoneVerified":false]
        do {
            let data = try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys])
            try PrivateFiles.write(data,to:resultURL)
        } catch { emit("记录保存失败：\(error.localizedDescription)") }
    }
}

final class CheckApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var check: AppleHardwareCheck!
    let status = NSTextField(labelWithString:"尚未开始")
    let current = NSTextField(wrappingLabelWithString:"")
    let text = NSTextView()
    let startButton = NSButton(title:"开始检查（120 秒）",target:nil,action:nil)
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let directory: URL
        if let i = args.firstIndex(of:"--output-directory"), i + 1 < args.count, args[i+1].hasPrefix("/") {
            directory = URL(fileURLWithPath:args[i+1],isDirectory:true)
        } else { directory = URL(fileURLWithPath:NSTemporaryDirectory(),isDirectory:true).appendingPathComponent("yaoban-apple-check-\(UUID().uuidString)",isDirectory:true) }
        check = AppleHardwareCheck(directory:directory)
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:850,height:690),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "遥伴 · 苹果遥控器适配检查"; window.delegate = self; window.minSize = NSSize(width:700,height:600)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top:24,left:24,bottom:24,right:24); root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
        let heading = NSTextField(labelWithString:"认识你的 Siri Remote"); heading.font = .systemFont(ofSize:25,weight:.semibold)
        let detail = NSTextField(wrappingLabelWithString:"第三代 · USB-C\n检查只读取这款苹果遥控器。按键仍可能执行 macOS 原有动作；本工具不发送键鼠、不录音，不改变小米遥控器设置。")
        let steps = NSTextField(wrappingLabelWithString:"配对后开始检查，依次点按：圆盘中心、上下左右、返回、TV、播放/暂停、静音、音量加减；按住侧边语音约 2 秒再松开，最后在圆盘滑动。\n这轮先跳过电源键：社区报告它可能直接使 Mac 睡眠。")
        status.font = .systemFont(ofSize:15,weight:.semibold); current.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
        startButton.target = self; startButton.action = #selector(start)
        for b in [NSButton(title:"开启输入监控",target:self,action:#selector(permission)),startButton,NSButton(title:"停止并保存",target:self,action:#selector(stop))] { buttons.addArrangedSubview(b) }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        text.isEditable = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; scroll.documentView = text
        let path = NSTextField(wrappingLabelWithString:"检查记录：\(check.resultURL.path)"); path.font = .systemFont(ofSize:11); path.textColor = .secondaryLabelColor
        for view in [heading,detail,buttons,status,current,steps,scroll,path] as [NSView] { root.addArrangedSubview(view) }
        scroll.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:160).isActive = true
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        check.changed = { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.refresh() }
        refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if args.contains("--ui-smoke") {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [self] in
                precondition(!check.active && check.interfaces.isEmpty)
                precondition(startButton.isEnabled && text.isEditable == false)
                print("PASS: native Apple check opens idle; no device listener, keyboard output or audio capture")
                NSApp.terminate(nil)
            }
        }
    }
    func refresh() {
        guard check != nil else { return }
        status.stringValue = check.active ? "检查中 · \(check.interfaces.count) 个苹果输入接口 · 电量 \(check.batteryText)" : (check.permissionGranted ? "输入监控已允许 · 点开始检查" : "等待输入监控权限 · 授权后回到这里开始")
        current.stringValue = "已观察到按下或松开：\(check.buttonRows.count) 项 / 26 项（含未测试的电源）"
        startButton.isEnabled = !check.active
        text.string = check.lines.suffix(350).joined(separator:"\n")
        text.scrollToEndOfDocument(nil)
    }
    @objc func start() { check.start() }
    @objc func stop() { check.stop() }
    @objc func permission() {
        check.requestPermission()
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); check.stop() }
}

let bundleID = Bundle.main.bundleIdentifier ?? "local.moss.YaobanAppleCheck"
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    existing.activate(options:[])
} else {
    let app = NSApplication.shared
    let delegate = CheckApp()
    app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
}
