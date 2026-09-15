import AppKit
import Darwin

// Separate from shortcut recording: subscribes only to system media events.
// No ordinary keyboard/mouse input is observed, stored or forwarded here.
final class AppleMediaKeySuppressor {
    var log: (String) -> Void = { _ in }
    private(set) var failure: String?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var ids = Set<UInt64>()
    private var policy = AppleMediaPolicy()
    private var lastLog: [AppleMediaKey:TimeInterval] = [:]
    private let timebase: Double = {
        var value = mach_timebase_info_data_t()
        guard mach_timebase_info(&value) == KERN_SUCCESS, value.denom != 0 else { return 1e-9 }
        return Double(value.numer)/Double(value.denom)/1e9
    }()
    // Optional private bridge, isolated behind symbol and null checks. Some
    // NX events have no embedded HID sender; they use bounded edge correlation.
    private typealias CopyHID = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias SenderID = @convention(c) (CFTypeRef) -> UInt64
    private static let copyHID: CopyHID? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",RTLD_LAZY),
              let symbol = dlsym(handle,"CGEventCopyIOHIDEvent") else { return nil }
        return unsafeBitCast(symbol,to:CopyHID.self)
    }()
    private static let senderID: SenderID? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY),
              let symbol = dlsym(handle,"IOHIDEventGetSenderID") else { return nil }
        return unsafeBitCast(symbol,to:SenderID.self)
    }()

    func note(button: AppleRemoteButton, down: Bool, timestamp: UInt64) {
        guard tap != nil, let key = AppleMediaKey(button:button), timestamp > 0 else { return }
        policy.note(key,down:down,time:Double(timestamp)*timebase)
    }
    @discardableResult func start(ids: Set<UInt64>, configuration: MappingConfiguration) -> Bool {
        let owned = Set(AppleMediaKey.allCases.filter { configuration.bindings[$0.source] != nil })
        guard !ids.isEmpty, !owned.isEmpty else { stop(); return true }
        if self.ids != ids || policy.owned != owned { policy.reset() }
        self.ids = ids; policy.owned = owned
        if tap != nil { checkHealth(); return true }
        let mask = CGEventMask(1) << 14
        guard let created = CGEvent.tapCreate(tap:.cghidEventTap,place:.headInsertEventTap,
            options:.defaultTap,eventsOfInterest:mask,callback:{ _,type,event,context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let receiver = Unmanaged<AppleMediaKeySuppressor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    receiver.checkHealth(); return Unmanaged.passUnretained(event)
                }
                return receiver.suppress(type,event) ? nil : Unmanaged.passUnretained(event)
            },userInfo:Unmanaged.passUnretained(self).toOpaque()) else {
            failure = "媒体键拦截需要辅助功能权限，请授权后重新检测"
            return false
        }
        guard let scheduled = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,created,0) else {
            CFMachPortInvalidate(created)
            failure = "媒体键拦截启动失败，请重新检测"
            return false
        }
        tap = created; source = scheduled
        CFRunLoopAddSource(CFRunLoopGetMain(),scheduled,.commonModes)
        CGEvent.tapEnable(tap:created,enable:true)
        failure = nil; log("苹果媒体拦截已就绪：仅播放、静音和音量事件。")
        return true
    }
    func checkHealth() {
        if let tap, !CGEvent.tapIsEnabled(tap:tap) { policy.reset(); CGEvent.tapEnable(tap:tap,enable:true) }
    }
    private func suppress(_ type: CGEventType,_ event: CGEvent) -> Bool {
        guard type.rawValue == 14, !ids.isEmpty, let native = NSEvent(cgEvent:event),
              native.subtype.rawValue == 8, let key = AppleMediaKey(rawValue:(native.data1 >> 16) & 0xffff) else { return false }
        let state = (native.data1 >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return false }
        var sender: UInt64 = 0
        if let copy = Self.copyHID, let identify = Self.senderID, let value = copy(event)?.takeRetainedValue() {
            sender = identify(value)
        }
        let origin: AppleMediaPolicy.Origin = sender == 0 ? .unknown : ids.contains(sender) ? .selected : .other
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        let synthetic = event.getIntegerValueField(.eventSourceUserData) != 0 || pid == Int64(getpid()) || (sender == 0 && pid > 0)
        let sample = AppleMediaClock.normalize(event.timestamp,ticksToSeconds:timebase,
                                              now:Double(mach_absolute_time())*timebase)
        let blocked = sample.map {
            policy.suppress(key,down:state == 0x0a,repeating:native.data1 & 1 != 0,
                            time:$0.seconds,origin:origin,synthetic:synthetic)
        } ?? false
        // Bounded diagnostics contain only these four media codes and attribution.
        // Defer file logging out of the event-tap callback.
        let now = ProcessInfo.processInfo.systemUptime
        if now - (lastLog[key] ?? -10) >= 1 {
            lastLog[key] = now
            let clock = sample.map { $0.rawTicks ? "系统时钟刻度" : "纳秒时钟" } ?? "时间无效"
            let evidence = (sender == 0 ? "时间关联" : ids.contains(sender) ? "目标设备" : "其他来源") + "，" + clock
            DispatchQueue.main.async { [weak self] in self?.log("媒体事件 \(key)：\(blocked ? "已拦截" : "放行")（\(evidence)）。") }
        }
        return blocked
    }
    func stop() {
        policy.reset(); policy.owned = []; ids = []; lastLog = [:]; failure = nil
        if let tap { CGEvent.tapEnable(tap:tap,enable:false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }
    deinit { stop() }
}
