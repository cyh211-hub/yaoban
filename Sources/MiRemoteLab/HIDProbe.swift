// Xiaomi Remote Lab — GPL-3.0.
import Foundation
import IOKit.hid
import IOBluetooth

final class HIDProbe {
    var log: (String) -> Void = { _ in }
    var status: (String) -> Void = { _ in }
    var onKeys: (Set<UInt16>, Set<UInt16>) -> Void = { _, _ in }
    var onDisconnect: () -> Void = {}
    var onConnect: () -> Void = {}
    var isConnected: Bool { device != nil }
    var targetIdentity: String?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var systemDevice: IOBluetoothDevice?
    var systemName: String? { RemoteBluetoothDevice.displayName(systemDevice?.name) }
    private var keys = Set<UInt16>()
    private var reportDiagnostics = false
    private var diagnosticReports: [UInt32:Data] = [:]

    // Enabled only during the existing 20-second remote-combination capture.
    // The device identity guard above this receiver excludes all other devices.
    func diagnoseReports(_ enabled: Bool) {
        reportDiagnostics = enabled; diagnosticReports = [:]
    }

    func start(requestPermission: Bool = false) {
        stop()
        guard targetIdentity != nil else { status("请先绑定遥控器"); return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            status("等待输入监控权限")
            log("请在系统设置 → 隐私与安全性 → 输入监控中开启「遥伴」，然后重新打开应用。")
            if requestPermission { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
            return
        }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x2717, kIOHIDProductIDKey: 0x32B8] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, result, _, dev in
            guard let context else { return }
            let p = Unmanaged<HIDProbe>.fromOpaque(context).takeUnretainedValue()
            guard p.manager != nil, p.device == nil,
                  RemoteHIDIdentity.make(transport: IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String,
                    location: (IOHIDDeviceGetProperty(dev, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint64Value) == p.targetIdentity else { return }
            guard result == kIOReturnSuccess else {
                p.status("按键监听连接失败")
                p.log("设备连接回调失败：\(result)。暂不接管按键。")
                return
            }
            p.device = dev
            p.systemDevice = RemoteBluetoothDevice.resolve(dev)
            p.status("已连接 · 可读取按下和松开")
            p.log("已普通监听目标遥控器；系统映射负责替换原生按键。")
            p.onConnect()
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, dev in
            guard let context else { return }
            let p = Unmanaged<HIDProbe>.fromOpaque(context).takeUnretainedValue()
            guard let current = p.device, CFEqual(current, dev) else { return }
            p.device = nil; p.keys = []
            p.status("遥控器已断开")
            p.log("HID 断开，清空所有按键状态。")
            p.onDisconnect()
        }, ctx)
        IOHIDManagerRegisterInputReportCallback(m, { context, result, sender, _, reportID, report, length in
            guard let context, result == kIOReturnSuccess, length > 0 else { return }
            let p = Unmanaged<HIDProbe>.fromOpaque(context).takeUnretainedValue()
            guard let current = p.device, let sender,
                  CFEqual(current, Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()) else { return }
            p.receive(reportID, Data(bytes: report, count: length))
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, 0)
        if result != kIOReturnSuccess { stop(); log("普通监听打开失败：\(result)"); status("无法读取按键：\(result)") }
        else if device == nil { status("等待遥控器按键连接") }
    }
    private func receive(_ id: UInt32, _ data: Data) {
        if reportDiagnostics, diagnosticReports[id] != data {
            if id == 1, data.count == 6 || data.count == 7 {
                log("组合诊断 · 按键报告：" + data.map { String(format:"%02X",$0) }.joined(separator:" "))
                diagnosticReports[id] = data
            } else if diagnosticReports[id] == nil {
                // Do not log vendor/audio payloads; only report shape.
                log("组合诊断 · 其他报告：编号 \(id)，长度 \(data.count)")
                diagnosticReports[id] = Data()
            }
        }
        guard let next = RemoteReport.parse(id: id, data: data), next != keys else { return }
        let old = keys; keys = next
        let down = next.subtracting(old), up = old.subtracting(next)
        if !down.isEmpty { log("按下：\(RemoteReport.name(down))") }
        if !up.isEmpty { log("松开：\(RemoteReport.name(up))") }
        if next.count > 1 { log("组合键实测：\(RemoteReport.name(next))（\(next.count) 键）") }
        onKeys(old, next)
    }
    func stop() {
        diagnoseReports(false)
        keys = []
        device = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        manager = nil
    }
}
