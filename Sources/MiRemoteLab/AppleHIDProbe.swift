import Foundation
import IOKit.hid
import IOBluetooth

// Public HID APIs only. Never probes a different Apple product or unknown identity.
final class AppleHIDProbe {
    struct Candidate: Equatable { let identity: String; let name: String }
    var targetIdentity: String?
    var onKeys: (Set<UInt16>,Set<UInt16>) -> Void = { _,_ in }
    var onMediaEdge: (AppleRemoteButton,Bool,UInt64) -> Void = { _,_,_ in }
    var onConnect: () -> Void = {}
    var onDisconnect: () -> Void = {}
    var status: (String) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    private(set) var isConnected = false
    private(set) var batteryReading = RemoteBatteryReading()
    var batteryChanged: () -> Void = {}
    private let batteryReader = AppleBatteryReader()
    private var manager: IOHIDManager?
    private var devices: [UInt64:IOHIDDevice] = [:]
    var seizedRegistryIDs: Set<UInt64> { isConnected ? Set(devices.keys) : [] }
    private var state = AppleButtonState()
    private var keys = Set<UInt16>()
    private var blocked = Set<AppleRemoteButton>()
    private var settle: DispatchWorkItem?
    private var connectionPolicy = AppleHIDConnectionPolicy()
    private var nextPresenceCheck: TimeInterval = 0
    private var generation = UUID()
    private var systemDevice: IOBluetoothDevice?
    var systemName: String? { RemoteBluetoothDevice.displayName(systemDevice?.name) }

    private static let match = [kIOHIDVendorIDKey:AppleButtonInput.vendorID,kIOHIDProductIDKey:AppleButtonInput.productID]
    private static func number(_ device: IOHIDDevice,_ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device,key as CFString) as? NSNumber)?.intValue
    }
    static func identity(_ device: IOHIDDevice) -> String? {
        guard AppleButtonInput.matches(vendor:number(device,kIOHIDVendorIDKey) ?? -1,
            product:number(device,kIOHIDProductIDKey) ?? -1,
            transport:IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String) else { return nil }
        return AppleRemoteIdentity.make(serial:IOHIDDeviceGetProperty(device,kIOHIDSerialNumberKey as CFString) as? String,
            location:(IOHIDDeviceGetProperty(device,kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint64Value,
            transport:IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String)
    }
    private static func registryID(_ device: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&id) == KERN_SUCCESS, id > 0 else { return nil }
        return id
    }
    private static func isButtonInterface(_ device: IOHIDDevice) -> Bool {
        number(device,kIOHIDPrimaryUsagePageKey) == 12 && number(device,kIOHIDPrimaryUsageKey) == 1
    }
    private static func isLive(_ id: UInt64) -> Bool {
        guard let matching = IORegistryEntryIDMatching(id) else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault,matching)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }
    static func candidates() -> [Candidate] {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return [] }
        let m = IOHIDManagerCreate(kCFAllocatorDefault,0)
        IOHIDManagerSetDeviceMatching(m,match as CFDictionary)
        guard IOHIDManagerOpen(m,0) == kIOReturnSuccess else { return [] }
        defer { IOHIDManagerClose(m,0) }
        let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> ?? []
        var result: [String:Candidate] = [:]
        for device in devices where isButtonInterface(device) {
            guard let identity = identity(device),let id = registryID(device),isLive(id),
                  let bluetooth = RemoteBluetoothDevice.resolve(device),bluetooth.isConnected() else { continue }
            result[identity] = Candidate(identity:identity,name:RemoteBluetoothDevice.displayName(bluetooth.name) ?? "Siri Remote USB-C · " + identity.suffix(4))
        }
        return result.values.sorted { $0.identity < $1.identity }
    }
    func start() {
        stop()
        guard let targetIdentity, AppleRemoteIdentity.valid(targetIdentity) else { status("请先添加苹果遥控器"); return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { status("等待输入监控权限"); return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault,0); manager = m
        IOHIDManagerSetDeviceMatching(m,Self.match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m,{ ctx,result,sender,_ in
            guard let ctx,let sender,result == kIOReturnSuccess else { return }
            let receiver = Unmanaged<AppleHIDProbe>.fromOpaque(ctx).takeUnretainedValue()
            guard let current = receiver.manager,
                  CFEqual(current,Unmanaged<IOHIDManager>.fromOpaque(sender).takeUnretainedValue()) else { return }
            receiver.scheduleReconcile()
        },context)
        IOHIDManagerRegisterDeviceRemovalCallback(m,{ ctx,_,sender,device in
            guard let ctx,let sender else { return }
            let receiver = Unmanaged<AppleHIDProbe>.fromOpaque(ctx).takeUnretainedValue()
            guard let current = receiver.manager,
                  CFEqual(current,Unmanaged<IOHIDManager>.fromOpaque(sender).takeUnretainedValue()) else { return }
            if let id = AppleHIDProbe.registryID(device),receiver.devices[id] != nil {
                receiver.deactivate()
                receiver.status("苹果遥控器已断开 · 等待重新连接")
                receiver.log("苹果按键接口断开，已取消长按与连发。")
                receiver.connectionPolicy.reset()
            }
            receiver.scheduleReconcile()
        },context)
        IOHIDManagerScheduleWithRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m,0)
        if result != kIOReturnSuccess { stop(); status("苹果按键监听打开失败：\(result)") }
        else { status("等待苹果遥控器连接"); scheduleReconcile() }
    }
    private func scheduleReconcile() {
        settle?.cancel()
        let expected = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self,self.generation == expected,self.manager != nil else { return }
            self.settle = nil
            self.reconcile()
        }
        settle = item
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:item)
    }
    // Called by the existing runtime timer. Poll only this receiver's registry
    // presence, never Bluetooth connect/pair, and never subscribe to other inputs.
    func checkConnection(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard manager != nil,now >= nextPresenceCheck else { return }
        nextPresenceCheck = now + 0.5
        if isConnected && (systemDevice?.isConnected() != true || devices.keys.contains(where:{ !Self.isLive($0) })) {
            deactivate()
            connectionPolicy.reset()
            status("苹果遥控器已断开 · 等待重新连接")
            log("系统蓝牙或苹果按键接口已断开，清理过期连接和按住状态。")
        }
        if settle == nil { reconcile() }
        if isConnected, let address = systemDevice?.addressString {
            let expected = generation
            batteryReader.refresh(address:address,now:now) { [weak self] percent in
                guard let self, self.generation == expected, self.isConnected else { return }
                _ = self.batteryReading.receive(Data([UInt8(percent)])); self.batteryChanged()
            }
        }
    }
    private func reconcile() {
        guard let manager else { return }
        let available = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var live: [UInt64:IOHIDDevice] = [:]
        for device in available where Self.identity(device) == targetIdentity {
            // Only the supported HID pages; leave page 32 to the OS. No feature writes.
            guard [1,12,13,0xFF00].contains(Self.number(device,kIOHIDPrimaryUsagePageKey) ?? -1),
                  let id = Self.registryID(device),Self.isLive(id) else { continue }
            live[id] = device
        }
        if let button = live.values.first(where:Self.isButtonInterface),let bluetooth = RemoteBluetoothDevice.resolve(button) {
            systemDevice = bluetooth
        }
        // macOS can keep the virtual HID objects alive after manually disconnecting
        // Bluetooth. Presence alone is therefore insufficient to arm the receiver.
        let bluetoothConnected = systemDevice?.isConnected() == true
        guard connectionPolicy.needsRebuild(liveInterfaces:Set(live.keys),systemConnected:bluetoothConnected) else { return }
        deactivate()
        guard bluetoothConnected,live.values.contains(where:Self.isButtonInterface),live.count <= 16 else {
            status("苹果遥控器已断开 · 等待重新连接")
            return
        }
        // Rebuild the whole current group, including surviving sibling interfaces.
        // A failed group is retried only after its live inventory changes or a manual restart.
        for id in live.keys.sorted() {
            guard let device = live[id],open(device,id:id) else { return }
        }
        arm()
    }
    private func open(_ device: IOHIDDevice,id: UInt64) -> Bool {
        let result = IOHIDDeviceOpen(device,IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            deactivate()
            status("无法独占苹果按键，请关闭其他遥控器工具后重新检测")
            log("苹果接口独占失败 \(result)；停止全部映射，未退回会重复触发的普通监听。")
            return false
        }
        devices[id] = device
        IOHIDDeviceRegisterInputValueCallback(device,{ ctx,result,_,value in
            guard let ctx,result == kIOReturnSuccess else { return }
            Unmanaged<AppleHIDProbe>.fromOpaque(ctx).takeUnretainedValue().receive(value)
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
        // Cache currently held states before arming, so switching mid-press cannot inject a press.
        if Self.isButtonInterface(device), let elements = IOHIDDeviceCopyMatchingElements(device,nil,0) as? [IOHIDElement] {
            for e in elements where IOHIDElementGetType(e) == kIOHIDElementTypeInput_Button {
                let value = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity:1)
                if IOHIDDeviceGetValue(device,e,value) == kIOReturnSuccess { receive(value.pointee.takeUnretainedValue()) }
                value.deallocate()
            }
        }
        if let percent = AppleButtonInput.battery(Self.number(device,"BatteryPercent")) {
            _ = batteryReading.receive(Data([UInt8(percent)]))
        }
        return true
    }
    private func arm() {
        guard manager != nil,devices.values.contains(where:Self.isButtonInterface) else { return }
        guard !isConnected else { return }
        blocked = state.buttons
        isConnected = true
        log("苹果按键已独占：\(devices.count) 个接口；电源不映射。")
        status("苹果按键已连接 · 按键通道已就绪")
        onConnect()
    }
    private func receive(_ value: IOHIDValue) {
        let e = IOHIDValueGetElement(value), device = IOHIDElementGetDevice(e)
        guard manager != nil, let id = Self.registryID(device), devices[id] != nil,
              Self.isButtonInterface(device), IOHIDElementGetType(e) == kIOHIDElementTypeInput_Button,
              IOHIDElementGetReportID(e) == 0xFB, IOHIDElementGetReportCount(e) == 1,
              IOHIDElementGetReportSize(e) == 1, IOHIDValueGetLength(value) == 1 else { return }
        let edges = state.receive(interface:id,cookie:UInt32(IOHIDElementGetCookie(e)),page:IOHIDElementGetUsagePage(e),
                          usage:IOHIDElementGetUsage(e),value:IOHIDValueGetIntegerValue(value))
        guard isConnected else { return }
        for edge in edges where !blocked.contains(edge.button) {
            onMediaEdge(edge.button,edge.pressed,IOHIDValueGetTimeStamp(value))
        }
        blocked.formIntersection(state.buttons)
        let next = Set(state.buttons.subtracting(blocked).compactMap(RemoteButtonLayout.source))
        guard next != keys else { return }
        let old = keys; keys = next
        onKeys(old,next)
    }
    private func deactivate() {
        batteryReader.stop()
        settle?.cancel(); settle = nil
        let wasConnected = isConnected; isConnected = false
        // Notify the owner before closing HID, to cancel long presses without executing short taps.
        if wasConnected { onDisconnect() }
        for device in devices.values {
            IOHIDDeviceRegisterInputValueCallback(device,nil,nil)
            IOHIDDeviceUnscheduleFromRunLoop(device,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device,IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
        devices.removeAll(); _ = state.reset(); keys = []; blocked = []; batteryReading = RemoteBatteryReading()
    }
    func stop() {
        generation = UUID()
        deactivate()
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager,nil,nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager,nil,nil)
            IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager,0)
        }
        manager = nil; connectionPolicy.reset(); nextPresenceCheck = 0
    }
}
