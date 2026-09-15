// Xiaomi Remote Lab — GPL-3.0.
import AppKit

final class ShortcutRecorder {
    var cancellationRect: () -> NSRect? = { nil }
    var preview: (String) -> Void = { _ in }
    var completed: ([UInt16]) -> Void = { _ in }
    var cancelled: (String) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    private(set) var isActive = false
    private weak var window: NSWindow?
    private var monitor: Any?
    private var timer: Timer?
    private var capture = ShortcutCapture()
    private var generation = 0
    private var finishing = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var filtersSystemEvents = false
    private var rawModifiers = Set<UInt16>()
    private var rawHeldModifiers = Set<UInt16>()
    private var physicalCapture = PhysicalModifierCapture()
    private var sawSystemEvent = false
    private var capturedScroll = false
    private let keyboardProbe = KeyboardSignalProbe()

    func begin(in window: NSWindow) {
        cancel("已取消录入，原设置保留。")
        guard CGEventSource.flagsState(.combinedSessionState).rawValue & ModifierIdentity.genericMask == 0 else {
            cancelled("请先松开所有键，再选择“创建映射”录入。"); return
        }
        self.window = window; capture = ShortcutCapture(); isActive = true; finishing = false
        rawModifiers = []; rawHeldModifiers = []; sawSystemEvent = false; capturedScroll = false; physicalCapture = PhysicalModifierCapture()
        log("选择“创建映射”录入开始：系统按键监听=\(CGPreflightListenEventAccess())，发送事件权限=\(CGPreflightPostEventAccess())")
        let ticket = generation
        preview("等待输入…")
        // A UI callback may cancel this session synchronously. Never install
        // event/keyboard listeners after cancellation (or over a newer session).
        guard isActive, generation == ticket else { return }
        startSystemTap()
        guard isActive, generation == ticket else { return }
        keyboardProbe.log = { [weak self] in self?.log($0) }
        keyboardProbe.ordinaryKeyDown = { [weak self] in self?.physicalCapture.ordinaryKeyDown() }
        keyboardProbe.modifier = { [weak self] usage, down in
            guard let self, self.isActive else { return }
            self.physicalCapture.modifier(usage, down: down)
            if down { self.rawModifiers.insert(usage); self.rawHeldModifiers.insert(usage) } else { self.rawHeldModifiers.remove(usage) }
            // If the window never receives a logical key, show where it stopped.
            if !self.sawSystemEvent {
                self.preview("键盘已发出 \(KeyboardKey.find(usage)?.name ?? "菜单键") · \(down ? "请松开" : "正在确认")")
            }
            if let candidate = self.physicalCapture.candidate { self.finishPhysicalModifier(candidate) }
        }
        keyboardProbe.start()
        guard isActive, generation == ticket else { return }
        // Local monitor consumes this app's shortcuts (including Command-Q),
        // while active only. It never records text or monitors another app.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.scrollWheel]) { [weak self] event in
            guard let self, self.isActive else { return event }
            if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(event.type), self.cancellationRect()?.contains(NSEvent.mouseLocation) == true {
                self.cancel(); return event
            }
            guard self.window?.isKeyWindow == true, NSApp.isActive else {
                self.cancel("窗口已切换，录入已取消。"); return event
            }
            if self.finishing { return nil }
            // The event tap is the authoritative stream when present. The local
            // monitor still consumes app shortcuts, without processing them twice.
            if event.type == .flagsChanged { self.log("窗口修饰事件：keyCode=\(event.keyCode)，flags=\(String(event.modifierFlags.rawValue,radix:16))") }
            if self.tap == nil { self.receive(event) }
            return nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.cancel(!self.rawModifiers.isEmpty && !self.sawSystemEvent ? "键盘有原始信号，但系统没有传来有效键值；诊断已记录。" : "等待超时，原设置保留。选择“创建映射”可重新录入。")
        }
    }
    private func startSystemTap() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let mask = [CGEventType.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.scrollWheel].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<ShortcutRecorder>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.cancel("系统暂停了按键录入，原设置保留。请选择“创建映射”重试。")
                return Unmanaged.passUnretained(event)
            }
            guard owner.isActive else { return Unmanaged.passUnretained(event) }
            guard owner.window?.isKeyWindow == true, NSApp.isActive else {
                owner.cancel("窗口已切换，录入已取消。")
                return Unmanaged.passUnretained(event)
            }
            if [.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel].contains(type) {
                let point = NSEvent.mouseLocation
                if owner.cancellationRect()?.contains(point) == true || owner.window?.frame.contains(point) != true {
                    owner.cancel("已取消录入，原设置保留。")
                    return Unmanaged.passUnretained(event)
                }
            }
            let suppress = owner.filtersSystemEvents
            if !owner.finishing, let input = NSEvent(cgEvent: event) {
                if [.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel].contains(type) { owner.sawSystemEvent = true }
                if type == .flagsChanged { owner.log("系统修饰事件：keyCode=\(input.keyCode)，flags=\(String(input.modifierFlags.rawValue,radix:16))") }
                owner.receive(input)
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }
        // Use an active recorder only if its permission already exists. Otherwise
        // a passive tap uses the user's existing Input Monitoring authorization.
        if CGPreflightPostEventAccess() {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: context)
            filtersSystemEvents = tap != nil
        }
        if tap == nil && CGPreflightListenEventAccess() {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: context)
            filtersSystemEvents = false
        }
        guard let tap else { log("系统事件监听不可用，使用窗口录入。"); return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log(filtersSystemEvents ? "系统录入已启用：录入期间拦截目标快捷键。" : "系统录入已启用：只读监听；窗口内快捷键由本应用处理。")
    }
    private func finishPhysicalModifier(_ usage: UInt16) {
        let ticket = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isActive, !self.finishing, self.generation == ticket,
                  !self.sawSystemEvent, self.physicalCapture.candidate == usage,
                  self.window?.isKeyWindow == true, NSApp.isActive else { return }
            guard self.keyboardProbe.hasUnmodifiedKeyboardService() else {
                self.cancel("键盘存在额外系统映射，不能直接按原始键值保存。诊断已记录。")
                return
            }
            self.log("原始按键录入成功：\(KeyboardKey.describe([usage]))；已确认按下和松开，未见系统事件，键盘无额外系统映射。")
            self.stop(); self.completed([usage])
        }
    }
    private func receive(_ event: NSEvent) {
        let result: CaptureProgress
        if [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.scrollWheel].contains(event.type) {
            let flags = UInt64(event.modifierFlags.rawValue)
            let modifiers = ModifierIdentity.active(flags:flags,eventCode:0,previous:capture.held)
            if !rawHeldModifiers.isEmpty && !rawHeldModifiers.isSubset(of: modifiers) {
                cancel("鼠标组合中的修饰键未收到系统键值，未保存不完整的组合。请先在系统键盘设置中对齐该键。"); return
            }
            if !modifiers.isEmpty { _ = capture.modifiers(modifiers) }
            let usage: UInt16
            if event.type == .scrollWheel {
                guard abs(event.scrollingDeltaY) > 0, !capturedScroll else { return }
                capturedScroll = true
                usage = event.scrollingDeltaY > 0 ? 0xF104 : 0xF105
                if capture.held.contains(usage) { return }
                _ = capture.key(usage, down: true)
                result = capture.key(usage, down: false)
            } else {
                usage = [.leftMouseDown,.leftMouseUp].contains(event.type) ? 0xF101 : [.rightMouseDown,.rightMouseUp].contains(event.type) ? 0xF102 : 0xF103
                let down = [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(event.type)
                guard down || capture.held.contains(usage) else { return }
                result = capture.key(usage, down: down)
            }
        } else if event.type == .flagsChanged {
            let flags = UInt64(event.modifierFlags.rawValue)
            let keys = ModifierIdentity.active(flags: flags, eventCode: event.keyCode, previous: capture.held)
            if !KeyboardKey.all.contains(where: { $0.code == event.keyCode && $0.isModifier }) {
                log("无法识别的修饰事件：keyCode=\(event.keyCode)，flags=\(String(flags,radix:16))")
                cancel("这个特殊键暂不支持录入，原设置保留。"); return
            }
            result = capture.modifiers(keys)
        } else {
            if event.isARepeat { return }
            guard let key = KeyboardKey.all.first(where: { $0.code == event.keyCode }), !key.isModifier else {
                cancel("这个按键暂不支持录入，原设置保留。"); return
            }
            result = capture.key(key.usage, down: event.type == .keyDown)
        }
        switch result {
        case .waiting: break
        case .holding(let keys): preview(KeyboardKey.describe(keys) + " · 松开后保存")
        case .invalid: cancel("请一次按下一组组合键，原设置保留。选择“创建映射”可重试。")
        case .complete(let keys):
            finishing = true
            let ticket = generation
            // Allow the remote's independent HID callback to reject a remote
            // press before committing it as a computer-keyboard binding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.isActive, ticket == self.generation else { return }
                self.stop(); self.completed(keys)
            }
        }
    }
    func cancel(_ reason: String = "已取消录入，原设置保留。") {
        guard isActive else { return }
        log("选择“创建映射”录入结束：\(reason)")
        stop(); cancelled(reason)
    }
    private func stop() {
        generation += 1; isActive = false; finishing = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; timer?.invalidate(); timer = nil; window = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil; filtersSystemEvents = false
        keyboardProbe.stop()
    }
}
