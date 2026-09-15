// Xiaomi Remote Lab — GPL-3.0.
import AppKit

final class KeyCalibration: NSObject, NSWindowDelegate {
    var log: (String) -> Void = { _ in }
    var apply: (UInt16) -> Void = { _ in }
    var activityChanged: () -> Void = {}
    var isActive: Bool { stage != nil }
    private var window: NSWindow?
    private let keyboardLabel = NSTextField(labelWithString: "键盘目标：尚未识别")
    private let remoteLabel = NSTextField(labelWithString: "遥控器输出：尚未识别")
    private let resultLabel = NSTextField(wrappingLabelWithString: "先识别键盘上的目标键，再对照遥控器麦克风键。")
    private let applyButton = NSButton(title: "将麦克风键设为键盘目标", target: nil, action: nil)
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var stage: String?
    private var pending: UInt16?
    private var pendingFlags: UInt64 = 0
    private var finishing = false
    private var microphoneSeen = false
    private var generation = 0
    private var keyboard: UInt16?
    private var remote: UInt16?

    func show() {
        if window == nil { makeWindow() }
        window?.center(); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 660,height: 365), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        w.title = "按键对齐 · 实按识别"; w.isReleasedWhenClosed = false; w.delegate = self; window = w
        let title = NSTextField(labelWithString: "按一下你实际想用的那颗键")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "不用猜 Alt、Windows 或 ⌘ 的名字。每一步只按一颗修饰键，按住约半秒再松开。豆包可能同时弹出，识别仍可继续。")
        note.textColor = .secondaryLabelColor
        let first = NSButton(title: "① 识别键盘上的目标键", target: self, action: #selector(captureKeyboard))
        let second = NSButton(title: "② 对照遥控器麦克风键", target: self, action: #selector(captureRemote))
        applyButton.target = self; applyButton.action = #selector(applyTarget); applyButton.isEnabled = false
        [keyboardLabel,remoteLabel].forEach { $0.font = .systemFont(ofSize: 17,weight: .medium); $0.isSelectable = true }
        let privacy = NSTextField(wrappingLabelWithString: "每次识别最多 45 秒，只读取 ⌘、⌥、⇧、⌃ 的按下和松开，不读取文字。完成或关闭窗口即停止。")
        privacy.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title,note,first,keyboardLabel,second,remoteLabel,resultLabel,applyButton,privacy])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 22),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    @objc func captureKeyboard() { begin("键盘") }
    @objc func captureRemote() { begin("遥控器") }
    private func begin(_ kind: String) {
        stop()
        guard CGEventSource.flagsState(.combinedSessionState).rawValue & ModifierIdentity.genericMask == 0 else {
            resultLabel.stringValue = "请先松开键盘和遥控器上的所有键，再点击识别。"; return
        }
        stage = kind; pending = nil; microphoneSeen = false; finishing = false
        if kind == "键盘" { keyboard = nil; keyboardLabel.stringValue = "键盘目标：等你按下并松开…" }
        else { remote = nil; remoteLabel.stringValue = "遥控器输出：等你按下并松开麦克风键…" }
        applyButton.isEnabled = false
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue, callback: { _, type, event, context in
            if let context {
                let owner = Unmanaged<KeyCalibration>.fromOpaque(context).takeUnretainedValue()
                if type == .flagsChanged {
                    owner.receive(code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags.rawValue)
                } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.stop(); owner.resultLabel.stringValue = "识别已暂停，请重新点击识别。"
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            stop(); resultLabel.stringValue = "暂时无法读取系统按键，请检查本应用的输入监控权限后重开。"; return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        activityChanged()
        resultLabel.stringValue = kind == "键盘" ? "现在请按键盘上你所说的“右梅花”，再松开。" : "现在只按遥控器麦克风键，再松开。"
        log("按键对齐：开始识别\(kind)，仅监听修饰键，最多 45 秒。")
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.stop(); self.resultLabel.stringValue = "本次未识别到完整按下和松开；点击对应按钮可重试。"
        }
    }
    func observeRemoteMicrophoneDown() { if stage != nil { microphoneSeen = true } }
    private func receive(code: UInt16, flags: UInt64) {
        guard stage != nil, !finishing else { return }
        if flags & ModifierIdentity.genericMask != 0 {
            guard let usage = ModifierIdentity.pressed(code: code, flags: flags) else {
                pending = nil; resultLabel.stringValue = "请只按一颗键，全部松开后再试。"; return
            }
            pending = usage; pendingFlags = flags
            resultLabel.stringValue = "已按下 \(KeyboardKey.describe([usage]))，请松开。"
        } else if let pending, KeyboardKey.find(pending)?.code == code {
            finishing = true
            let ticket = generation
            // HID reports and window-server events travel on separate queues.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, ticket == self.generation, let kind = self.stage else { return }
                let sawRemote = self.microphoneSeen
                let pressFlags = self.pendingFlags
                self.stop()
                guard (kind == "遥控器") == sawRemote else {
                    self.resultLabel.stringValue = kind == "键盘" ? "这次收到的是遥控器，请改按电脑键盘上的目标键。" : "未同时收到遥控器麦克风报告，请重试。"
                    return
                }
                if kind == "键盘" { self.keyboard = pending; self.keyboardLabel.stringValue = "键盘目标：\(KeyboardKey.describe([pending]))" }
                else { self.remote = pending; self.remoteLabel.stringValue = "遥控器输出：\(KeyboardKey.describe([pending]))" }
                self.log("按键对齐实测：\(kind) = \(KeyboardKey.describe([pending]))；keyCode=\(code)，按下 flags=\(String(pressFlags,radix:16))，松开 flags=\(String(flags,radix:16))")
                self.applyButton.isEnabled = self.keyboard != nil
                if let a = self.keyboard, let b = self.remote {
                    self.resultLabel.stringValue = a == b ? "两者一致：系统收到的是同一个键，按下和松开均已确认。" : "两者不同：可点击下方按钮，让麦克风键跟随键盘目标。"
                } else { self.resultLabel.stringValue = "已确认按下与松开。再识别另一项即可比较。" }
            }
        }
    }
    @objc private func applyTarget() {
        guard stage == nil, let keyboard else { return }
        apply(keyboard)
        remote = nil; remoteLabel.stringValue = "遥控器输出：设置已提交，请再次对照"
        resultLabel.stringValue = "已按键盘目标提交映射。请看主窗口状态，再点②实测。"
    }
    func stop() {
        generation += 1; stage = nil; pending = nil; finishing = false
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil
        activityChanged()
    }
    func windowWillClose(_ notification: Notification) { stop() }
    func windowDidResignKey(_ notification: Notification) { stop() }
}
