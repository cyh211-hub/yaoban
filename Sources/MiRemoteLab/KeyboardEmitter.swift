// Xiaomi Remote Lab — GPL-3.0.
import AppKit

final class KeyboardEmitter {
    static let tagPrefix: Int64 = 0x4D69524300000000
    static let receiptMask: Int64 = 0xFFFFFFFF
    var log: (String) -> Void = { _ in }
    var status: (String) -> Void = { _ in }
    var failed: (String) -> Void = { _ in }
    private var state = KeyboardOutputState()
    private let source = CGEventSource(stateID: .privateState)
    private let channel: KeyboardEventChannel
    private let scheduleReceiptCheck: (@escaping () -> Void) -> Void
    private let clock: () -> TimeInterval
    private let pointerSnapshot: () -> (CGPoint,Set<UInt16>)
    private var resumeSnapshotUntil: TimeInterval?
    private var trackedKeys: Set<UInt16> = []
    private var prepared = false
    var observationChanged: (Bool) -> Void = { _ in }
    var isObserving: Bool { channel.isEnabled }
    private var lifecycle: UInt64 = 0
    private var receiptWarning = false
    private var nextReceipt: Int64 = 0
    private struct Pending {
        let description: String
        let code: Int64
        let type: CGEventType
        let flags: UInt64
    }
    private var awaiting: [Int64: Pending] = [:]
    private(set) var failure: String?
    var isRunning: Bool { prepared && failure == nil && channel.hasAccess }

    init(channel: KeyboardEventChannel = QuartzKeyboardEventChannel(),
         scheduleReceiptCheck: @escaping (@escaping () -> Void) -> Void = { check in
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: check)
         }, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pointerSnapshot: @escaping () -> (CGPoint,Set<UInt16>) = {
             let buttons: [(UInt16,CGMouseButton)] = [(0xF101,.left),(0xF102,.right),(0xF103,.center)]
             return (CGEvent(source:nil)?.location ?? .zero,Set(buttons.filter { CGEventSource.buttonState(.hidSystemState,button:$0.1) }.map(\.0)))
         }) {
        self.channel = channel; self.scheduleReceiptCheck = scheduleReceiptCheck; self.clock = clock; self.pointerSnapshot = pointerSnapshot
    }

    @discardableResult func start() -> Bool {
        if isRunning { return true }
        guard failure == nil, channel.hasAccess else { return false }
        prepared = true
        log("按键发送已就绪；空闲时不监听全局键鼠，遥控器动作时按需启用。")
        return true
    }

    private func beginObservation(for usage: UInt16) -> Bool {
        if let until = resumeSnapshotUntil, clock() >= until, state.virtual.isEmpty {
            state = KeyboardOutputState(); trackedKeys = []; resumeSnapshotUntil = nil
        }
        let required = Set<UInt16>(0xE0...0xE7).union([usage])
        let additional = required.subtracting(trackedKeys)
        if !additional.isEmpty {
            for key in channel.physicalSnapshot(for:additional) { state.physicalEdge(key,down:true) }
            trackedKeys.formUnion(additional)
        }
        if channel.isEnabled { return channel.includeObservation(for:[usage]) }
        let opened = channel.start(observing:[usage], { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.receive(type, event)
        })
        observationChanged(opened)
        return opened
    }
    private func finishIdleObservation() {
        guard state.virtual.isEmpty, awaiting.isEmpty else { return }
        channel.stop(); state = KeyboardOutputState(); trackedKeys = []; resumeSnapshotUntil = nil
        observationChanged(false)
    }
    private func deferIdleFinish() {
        let generation = lifecycle
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lifecycle == generation else { return }
            self.finishIdleObservation()
        }
    }

    // Construction is tested without posting any keyboard input to the system.
    static func makeEvent(usage: UInt16, down: Bool, flags: UInt64, source: CGEventSource?, receipt: Int64, isRepeat: Bool = false) -> CGEvent? {
        guard let key = KeyboardKey.find(usage) else { return nil }
        let created: CGEvent?
        if key.isScroll {
            guard down else { return nil }
            created = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: usage == 0xF104 ? 3 : -3, wheel2: 0, wheel3: 0)
        } else if key.isMouse {
            let button: CGMouseButton = usage == 0xF101 ? .left : usage == 0xF102 ? .right : .center
            let type: CGEventType = usage == 0xF101 ? (down ? .leftMouseDown : .leftMouseUp) : usage == 0xF102 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            created = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGEvent(source:nil)?.location ?? .zero, mouseButton: button)
            created?.setIntegerValueField(.mouseEventClickState, value: 1)
        } else {
            created = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down)
            created?.type = key.isModifier ? .flagsChanged : (down ? .keyDown : .keyUp)
        }
        guard let event = created else { return nil }
        event.flags = CGEventFlags(rawValue: flags)
        if !key.isMouse { event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat && down && !key.isModifier ? 1 : 0) }
        event.setIntegerValueField(.eventSourceUserData, value: tagPrefix | (receipt & receiptMask))
        return event
    }
    func send(_ usage: UInt16, down: Bool) {
        guard !down || isRunning else { return }
        guard KeyboardKey.find(usage) != nil else { return }
        if down, !beginObservation(for:usage) { fail("无法启用按键协调，请检查权限后重新检测。"); return }
        let changed = state.virtualEdge(usage, down: down)
        if changed, !(KeyboardKey.find(usage)?.isScroll == true && !down) { post(usage,down:down) }
        if !down { deferIdleFinish() }
    }
    func repeatKey(_ usage: UInt16) {
        guard isRunning, state.virtual.contains(usage), !state.physical.contains(usage), KeyboardKey.find(usage)?.isModifier == false else { return }
        if KeyboardKey.find(usage)?.isMouse == true && KeyboardKey.find(usage)?.isScroll == false { return }
        post(usage, down: true, isRepeat: true)
    }
    // Touch motion uses existing output permission, with no event tap or key recording.
    func movePointer(x:Double,y:Double,scroll:Bool) {
        guard isRunning, x.isFinite, y.isFinite, abs(x) <= 0.6, abs(y) <= 0.6 else { return }
        let event: CGEvent?
        if scroll {
            let vertical = Int32((y * 600).rounded()), horizontal = Int32((-x * 600).rounded())
            guard vertical != 0 || horizontal != 0 else { return }
            event = CGEvent(scrollWheelEvent2Source:source,units:.pixel,wheelCount:2,wheel1:vertical,wheel2:horizontal,wheel3:0)
        } else {
            guard abs(x) + abs(y) > 0.0005 else { return }
            let (location,physicalButtons) = pointerSnapshot()
            let point = CGPoint(x:location.x + x * 1100,y:location.y - y * 1100)
            let left = state.virtual.contains(0xF101) || physicalButtons.contains(0xF101)
            let right = state.virtual.contains(0xF102) || physicalButtons.contains(0xF102)
            let middle = state.virtual.contains(0xF103) || physicalButtons.contains(0xF103)
            let type: CGEventType = left ? .leftMouseDragged : right ? .rightMouseDragged : middle ? .otherMouseDragged : .mouseMoved
            let button: CGMouseButton = left ? .left : right ? .right : middle ? .center : .left
            event = CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:button)
            event?.setIntegerValueField(.mouseEventDeltaX,value:Int64((x * 1100).rounded()))
            event?.setIntegerValueField(.mouseEventDeltaY,value:Int64((-y * 1100).rounded()))
        }
        guard let event else { return }
        let virtualFlags = state.virtual.reduce(UInt64(0)) { $0 | ModifierIdentity.genericFlag($1) | (ModifierIdentity.sideMasks[$1] ?? 0) }
        event.flags = CGEventFlags(rawValue:channel.currentFlags | virtualFlags)
        event.setIntegerValueField(.eventSourceUserData,value:Self.tagPrefix)
        channel.post(event)
    }
    private func post(_ usage: UInt16, down: Bool, isRepeat: Bool = false) {
        let flags = state.flags(preserving: channel.currentFlags)
        nextReceipt = (nextReceipt + 1) & Self.receiptMask
        let receipt = nextReceipt
        guard let event = Self.makeEvent(usage: usage, down: down, flags: flags, source: source, receipt: receipt, isRepeat: isRepeat) else { return }
        let description = "\(KeyboardKey.describe([usage])) \(isRepeat ? "连发" : down ? "按下" : "松开")"
        awaiting[receipt] = Pending(description: description, code: event.getIntegerValueField(.keyboardEventKeycode), type: event.type, flags: flags)
        log("提交输出：\(description)，keyCode=\(event.getIntegerValueField(.keyboardEventKeycode))，type=\(event.type.rawValue)，flags=\(String(flags,radix:16))")
        channel.post(event)
        let generation = lifecycle
        scheduleReceiptCheck { [weak self] in
            guard let self, self.lifecycle == generation,
                  let missing = self.awaiting.removeValue(forKey: receipt) else { return }
            defer { self.finishIdleObservation() }
            guard self.channel.hasAccess, self.channel.isEnabled else {
                self.fail("按键通道或权限不可用；请检查权限后点击重新检测。")
                return
            }
            // A preceding input-method tap may consume the shortcut. Absence
            // here is not proof of failed delivery: never replay, release a held
            // key, stop speech, or disable later mappings on that basis alone.
            if !self.receiptWarning {
                self.receiptWarning = true
                let message = "已提交\(missing.description)，入口未观察到回执，可能已由输入法处理；继续跟随实体按下与松开，不补发按键。"
                self.log(message); self.status("按键已提交 · 请以目标应用响应为准")
            }
        }
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            channel.enable()
            fail("系统暂停了按键通道，已请求释放按键；请点击重新检测。")
            return Unmanaged.passUnretained(event)
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        if tag & ~Self.receiptMask == Self.tagPrefix {
            if let pending = awaiting.removeValue(forKey: tag & Self.receiptMask) {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let relevantFlags = ModifierIdentity.genericMask | ModifierIdentity.sideMasks.values.reduce(0, |)
                if code != pending.code || type != pending.type || event.flags.rawValue & relevantFlags != pending.flags & relevantFlags {
                    fail("系统入口收到的键值与目标不一致；已暂停发送，请重新检测。")
                } else {
                    receiptWarning = false
                    log("系统入口已收到：\(pending.description)，keyCode=\(code)，type=\(type.rawValue)，flags=\(String(event.flags.rawValue,radix:16))")
                    status("已核对 \(pending.description) · 应用响应仍以实测为准")
                }
            }
            deferIdleFinish()
            return Unmanaged.passUnretained(event)
        }
        if [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp].contains(type) {
            let usage: UInt16 = [.leftMouseDown,.leftMouseUp].contains(type) ? 0xF101 : [.rightMouseDown,.rightMouseUp].contains(type) ? 0xF102 : 0xF103
            let down = [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type)
            if trackedKeys.contains(usage) { state.physicalEdge(usage, down: down) }
            if !down && state.virtual.contains(usage) { return nil }
        }
        if type == .mouseMoved {
            if state.virtual.contains(0xF101) { event.type = .leftMouseDragged; event.setIntegerValueField(.mouseEventButtonNumber,value:0) }
            else if state.virtual.contains(0xF102) { event.type = .rightMouseDragged; event.setIntegerValueField(.mouseEventButtonNumber,value:1) }
            else if state.virtual.contains(0xF103) { event.type = .otherMouseDragged; event.setIntegerValueField(.mouseEventButtonNumber,value:2) }
        }
        // Retain held key identities in memory only; never log keyboard text.
        if [.keyDown,.keyUp,.flagsChanged].contains(type),
           let key = trackedKeys.compactMap(KeyboardKey.find).first(where: { $0.code == event.getIntegerValueField(.keyboardEventKeycode) }) {
            let down: Bool
            if key.isModifier {
                guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
                down = ModifierIdentity.active(flags: event.flags.rawValue, eventCode: key.code, previous: state.physical).contains(key.usage)
            } else { down = type == .keyDown }
            state.physicalEdge(key.usage, down: down)
            if !down && !key.isModifier && state.virtual.contains(key.usage) { return nil }
        }
        if !state.virtual.isEmpty {
            var flags = event.flags.rawValue
            for key in state.virtual { flags |= ModifierIdentity.genericFlag(key) | (ModifierIdentity.sideMasks[key] ?? 0) }
            event.flags = CGEventFlags(rawValue: flags)
        }
        return Unmanaged.passUnretained(event)
    }
    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message; log(message); status(message)
        let generation = lifecycle
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lifecycle == generation, self.failure == message else { return }
            self.failed(message)
        }
    }
    func recover() {
        // Keep the physical snapshot across an immediate restart. A fresh HID
        // snapshot could still contain our just-posted asynchronous key-up.
        lifecycle &+= 1
        failure = nil; awaiting = [:]; receiptWarning = false
        // Recreate the channel on the next start; enabling the old tap alone
        // does not repair stale or reordered stream observation.
        channel.stop()
        resumeSnapshotUntil = clock() + 0.7
        prepared = false; observationChanged(false)
    }
    func stop() {
        lifecycle &+= 1
        channel.stop(); state = KeyboardOutputState(); trackedKeys = []; prepared = false; resumeSnapshotUntil = nil
        awaiting = [:]; failure = nil; receiptWarning = false
        observationChanged(false)
    }
}
