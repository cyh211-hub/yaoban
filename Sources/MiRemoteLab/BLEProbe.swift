// Xiaomi Remote Lab — GPL-3.0. ATVV interoperability based on Open Voice Bridge.
import Foundation
import CoreBluetooth

final class BLEProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var log: (String) -> Void = { _ in }
    var status: (String) -> Void = { _ in }
    var meter: (Double, Double) -> Void = { _, _ in }
    var saved: (URL) -> Void = { _ in }
    var batteryChanged: () -> Void = {}
    private(set) var batteryReading = RemoteBatteryReading()
    private var batteryCharacteristic: CBCharacteristic?
    private var batteryTimer: Timer?
    private let batteryService = CBUUID(string:"180F")
    private let batteryLevel = CBUUID(string:"2A19")
    var diagnostics: DiagnosticsStore?
    var binding: RemoteBinding?
    var bindingStatus: (String) -> Void = { _ in }
    private(set) var needsBindingSelection = false
    private var authorization = VoiceAuthorization()
    private var pendingStart: (Data, TimeInterval)?
    private var controlWindow = -1.0
    private var controlCount = 0
    private var audioWindow = -1.0
    private var audioBytes = 0
    var testingEnabled = false { didSet { if !testingEnabled && !bridgingEnabled { finish("收音已关闭") } } }
    var bridgingEnabled = true { didSet { if !bridgingEnabled && !testingEnabled { finish("收音已关闭") } } }
    var voiceStarted: () -> Void = {}
    var decodedSamples: ([Int16]) -> Void = { _ in }
    var voiceEnded: () -> Void = {}
    private var central: CBCentralManager?
    private var remote: CBPeripheral?
    private var tx: CBCharacteristic?
    private var subscribed = Set<String>()
    private var caps: ATVVCapabilities?
    private var requestedCaps = false
    private var model: String?
    private var timer: Timer?
    private var voiceTimer: Timer?
    private var noAudioTimer: Timer?
    private var requested = false
    private var streaming = false
    private var session: UInt8 = 0
    private var pcm = [Int16]()
    private var sampleCount = 0
    private var diagnosticADPCM = Data()
    private var diagnosticSync: [[String: Int]] = []
    private var maxReceiveGap = 0.0
    private var lastAudioAt: TimeInterval?
    private var packetCount = 0
    private var decoder = IMAADPCMDecoder()
    private var accumulator = FrameAccumulator()
    private var sync: (Int, Int)?
    private let service = CBUUID(string: ATVVProtocol.serviceUUID)
    private let info = CBUUID(string: "180A")
    var linkConnected: Bool { remote?.state == .connected }
    var voiceReady: Bool { linkConnected && ready }
    var radioAvailability: RemoteRadio {
        guard let central else { return .checking }
        switch central.state {
        case .poweredOn: return .ready
        case .poweredOff: return .off
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        default: return .checking
        }
    }

    var hidConnected: () -> Bool = { false }
    private var connectionPolicy = RemoteConnectionPolicy()
    func prepareDiscovery() { if central == nil { start() } }
    func ensureConnection() {
        guard let central, central.state == .poweredOn, let binding else { return }
        let connected = central.retrieveConnectedPeripherals(withServices:[service,CBUUID(string:"1812")])
            .first { $0.identifier == binding.peripheralID && candidate($0) }
        guard connectionPolicy.shouldAttach(hidConnected:hidConnected(),systemConnected:connected != nil,
                                             pairingInvalid:needsBindingSelection) else { return }
        guard remote == nil, let connected else { return }
        connect(connected)
    }
    func start() {
        stop()
        connectionPolicy = RemoteConnectionPolicy()
        status("等待系统连接遥控器")
        central = CBCentralManager(delegate:self,queue:.main)
    }
    // A link failure keeps the central alive so radio status stays accurate;
    // it never starts a new pairing request from a cached peripheral identifier.
    private func clearLink(cancel: Bool) {
        authorization.reset(); pendingStart = nil
        finish("连接关闭")
        timer?.invalidate(); timer = nil
        batteryTimer?.invalidate(); batteryTimer = nil; batteryCharacteristic = nil
        let previous = remote
        remote = nil; tx = nil; caps = nil; model = nil
        subscribed = []; requestedCaps = false
        previous?.delegate = nil
        if cancel, let previous { central?.cancelPeripheralConnection(previous) }
        batteryReading = RemoteBatteryReading(); batteryChanged()
    }
    func stop() {
        clearLink(cancel:true)
        central?.stopScan(); central?.delegate = nil; central = nil
    }
    func systemDisconnected() {
        clearLink(cancel:true)
        _ = connectionPolicy.shouldAttach(hidConnected:false,systemConnected:false,pairingInvalid:needsBindingSelection)
        status("等待系统重新连接；设备和键位已保留")
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c === central else { return }
        guard c.state == .poweredOn else {
            clearLink(cancel:false)
            _ = connectionPolicy.shouldAttach(hidConnected:false,systemConnected:false,pairingInvalid:needsBindingSelection)
            status(c.state == .unauthorized ? "等待蓝牙权限" : "蓝牙未就绪（\(c.state.rawValue)）")
            return
        }
        guard binding != nil else { status("请添加已在系统中连接的遥控器"); return }
        status("等待系统连接；按键与声音分别检测")
        ensureConnection()
    }
    func connectedCandidates() -> [(UUID, String)] {
        guard let central, central.state == .poweredOn else { return [] }
        return central.retrieveConnectedPeripherals(withServices: [service, CBUUID(string: "1812")])
            .filter { candidate($0) }.map { ($0.identifier, $0.name ?? "小米遥控器") }
    }
    func microphoneChanged(down: Bool) {
        guard binding != nil else { return }
        if down {
            guard authorization.press() else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let pending = pendingStart, now - pending.1 <= 0.3, authorization.acceptPending(now: now) {
                pendingStart = nil; processStart(pending.0)
            } else { pendingStart = nil }
        } else {
            authorization.release(); pendingStart = nil
            finish("麦克风按键已松开")
        }
    }
    private func candidate(_ p: CBPeripheral) -> Bool {
        ["mi rc", "xiaomi bluetooth remote 2 pro", "小米蓝牙语音遥控器"].contains((p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    private func connect(_ p: CBPeripheral) {
        guard p.identifier == binding?.peripheralID else { return }
        remote = p; p.delegate = self
        status("读取遥控器型号与语音服务")
        central?.connect(p); timeout()
    }
    private func timeout() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, !self.ready else { return }
            self.log("连接或能力查询超时；可唤醒遥控器后点击重新检测。")
            self.clearLink(cancel:true); self.status("语音连接超时，请检查系统连接后重新检测")
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard c === central, p === remote else { return }
        needsBindingSelection = false
        p.discoverServices([service, info, batteryService])
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard c === central, p === remote else { return }
        log("连接失败：\(error?.localizedDescription ?? "未知错误")")
        let pairingChanged = (error as? CBError)?.code == .peerRemovedPairingInformation
        needsBindingSelection = needsBindingSelection || pairingChanged
        clearLink(cancel:false); status(needsBindingSelection ? "系统配对记录已变化，请重新选择遥控器；键位模式保留" : "连接失败，请重新检测")
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard c === central, p === remote else { return }
        log("蓝牙断开：\(error?.localizedDescription ?? "正常断开")")
        needsBindingSelection = needsBindingSelection || (error as? CBError)?.code == .peerRemovedPairingInformation
        clearLink(cancel:false); status(needsBindingSelection ? "系统配对记录已变化，请重新选择遥控器；键位模式保留" : "遥控器已断开，请重新检测")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === remote else { return }
        if let error { log("服务发现失败：\(error.localizedDescription)"); return }
        for s in p.services ?? [] {
            log("发现服务：\(s.uuid.uuidString)")
            if s.uuid == info { p.discoverCharacteristics([CBUUID(string: "2A24"), CBUUID(string: "2A26")], for: s) }
            if s.uuid == service { p.discoverCharacteristics(nil, for: s) }
            if s.uuid == batteryService { p.discoverCharacteristics([batteryLevel],for:s) }
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard p === remote else { return }
        if let error { log("通道发现失败：\(error.localizedDescription)"); return }
        for ch in s.characteristics ?? [] {
            if s.uuid == batteryService {
                guard ch.uuid == batteryLevel else { continue }
                batteryCharacteristic = ch
                if ch.properties.contains(.read) {
                    p.readValue(for:ch)
                    batteryTimer?.invalidate()
                    batteryTimer = Timer.scheduledTimer(withTimeInterval:300,repeats:true) { [weak self] _ in
                        guard let self, let remote = self.remote, remote.state == .connected,
                              !self.authorization.held, let characteristic = self.batteryCharacteristic else { return }
                        remote.readValue(for:characteristic)
                    }
                }
                if ch.properties.contains(.notify) || ch.properties.contains(.indicate) { p.setNotifyValue(true,for:ch) }
                continue
            }
            if s.uuid == info { p.readValue(for: ch); continue }
            switch ch.uuid.uuidString {
            case ATVVProtocol.transmitUUID: tx = ch
            case ATVVProtocol.audioUUID, ATVVProtocol.controlUUID: p.setNotifyValue(true, for: ch)
            default: break
            }
        }
        requestCapabilities()
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard p === remote else { return }
        // Battery notification success/failure must not alter ATVV subscriptions.
        if ch.service?.uuid == batteryService { return }
        if let error { log("订阅失败：\(error.localizedDescription)"); return }
        if ch.isNotifying { subscribed.insert(ch.uuid.uuidString) }
        else { subscribed.remove(ch.uuid.uuidString); finish("语音通知已停止") }
        requestCapabilities()
    }
    private func requestCapabilities() {
        guard !requestedCaps, model == "RC003" || model == "RC003-MS", tx != nil,
              subscribed.contains(ATVVProtocol.audioUUID), subscribed.contains(ATVVProtocol.controlUUID) else { return }
        requestedCaps = true
        write(ATVVProtocol.getCapabilitiesV10)
    }
    private var ready: Bool {
        caps != nil && (model == "RC003" || model == "RC003-MS") && subscribed.count == 2 && tx != nil
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard p === remote else { return }
        if let error { log("命令写入失败：\(error.localizedDescription)"); finish("命令写入失败") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard p === remote else { return }
        if ch.service?.uuid == batteryService {
            guard ch.uuid == batteryLevel else { return }
            if error == nil, let value = ch.value, batteryReading.receive(value) {
                log("遥控器电量：\(batteryReading.percent!)%")
            } else { batteryReading = RemoteBatteryReading() }
            batteryChanged(); return
        }
        if let error { log("数据读取失败：\(error.localizedDescription)"); return }
        guard let data = ch.value, data.count <= 512 else { return }
        switch ch.uuid.uuidString {
        case "2A24":
            model = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            log("实机型号：\(model ?? "无法解码")")
            requestCapabilities()
        case "2A26": log("实机固件：\(String(data: data, encoding: .utf8) ?? "无法解码")")
        case ATVVProtocol.controlUUID: control(data)
        case ATVVProtocol.audioUUID: audio(data)
        default: break
        }
    }
    private func write(_ data: Data) {
        guard let p = remote, let tx else { return }
        p.writeValue(data, for: tx, type: tx.properties.contains(.write) ? .withResponse : .withoutResponse)
    }
    private func open() {
        guard ready, let caps else { log("语音通道尚未就绪，未打开麦克风。") ; return }
        guard !requested && !streaming else { return }
        prepareSession()
        log("遥控器语音键请求开麦。")
        status("已请求开麦 · 等待真实音频")
        write(ATVVProtocol.microphoneOpen(version: caps.version, codec: caps.selectedCodec))
    }
    private func prepareSession() {
        requested = true; pcm = []; session = 0; sampleCount = 0
        diagnosticADPCM = Data(); diagnosticSync = []; maxReceiveGap = 0; lastAudioAt = nil; packetCount = 0
        decoder.reset(); accumulator.reset(); sync = nil
        noAudioTimer?.invalidate()
        noAudioTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.sampleCount == 0 else { return }
            self.log("4 秒内未收到遥控器音频；此次收音尚未成功。")
            self.finish("开麦超时")
        }
        voiceTimer?.invalidate()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in self?.finish("已达到单次 60 秒测试上限") }
    }
    private func control(_ data: Data) {
        let b = Array(data)
        guard let op = b.first, b.count <= 512 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let second = floor(now)
        if second != controlWindow { controlWindow = second; controlCount = 0 }
        controlCount += 1
        guard controlCount <= 200 else { finish("控制消息过于频繁，已停止收音"); return }
        if op == 0x0B {
            guard requestedCaps, let c = ATVVCapabilities.parse(data), c.codecs & 2 != 0,
                  c.frameSize > 0, c.frameSize <= 4096, c.sampleRate == 16_000 else {
                log("不支持或无效的音频能力响应。") ; return
            }
            caps = c; timer?.invalidate()
            status("\(model ?? "遥控器") · 16 kHz 语音通道就绪")
            log("实机语音能力已确认：16 kHz、单声道，压缩帧 \(c.frameSize) 字节。")
            return
        }
        guard ready, testingEnabled || bridgingEnabled else { return }
        switch op {
        case 0x08, 0x04:
            if !requested {
                guard authorization.request(now: now) else {
                    if !authorization.held {
                        pendingStart = (data, now)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                            guard let self, let pending = self.pendingStart, pending.1 == now else { return }
                            self.pendingStart = nil
                            self.log("已拒绝没有实体麦克风按键授权的语音请求。")
                        }
                    }
                    return
                }
            }
            processStart(data)
        case 0x00: if requested || streaming { finish("遥控器结束麦克风会话") }
        case 0x0A:
            guard requested, authorization.held, b.count >= 7, b[6] <= 88 else { return }
            sync = (Int(Int16(bitPattern: UInt16(b[4]) << 8 | UInt16(b[5]))), Int(b[6]))
            accumulator.reset()
        default: break
        }
    }
    private func processStart(_ data: Data) {
        guard ready, authorization.held, testingEnabled || bridgingEnabled else { return }
        let b = Array(data)
        if b.first == 0x08 { if !requested && !streaming { open() }; return }
        guard b.first == 0x04, b.count >= 3, b[2] == 2 else { finish("设备返回不支持的编码"); return }
        if !requested { prepareSession() }
        session = b.count >= 4 ? b[3] : 0
        if !streaming { streaming = true; voiceStarted() }
    }
    private func audio(_ data: Data) {
        guard testingEnabled || bridgingEnabled, requested, streaming, authorization.held, ready, let caps, data.count <= 512 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let second = floor(now)
        if second != audioWindow { audioWindow = second; audioBytes = 0 }
        audioBytes += data.count
        guard audioBytes <= 64_000 else { finish("音频数据过于频繁，已停止收音"); return }
        if let previous = lastAudioAt { maxReceiveGap = max(maxReceiveGap, now - previous) }
        lastAudioAt = now; packetCount += 1
        for frame in accumulator.append(data, frameSize: caps.frameSize) {
            if let sync {
                if testingEnabled { diagnosticSync.append(["byteOffset":diagnosticADPCM.count,"predictor":sync.0,"stepIndex":sync.1]) }
                decoder.reset(predictor: sync.0, stepIndex: sync.1); self.sync = nil
            }
            if testingEnabled { diagnosticADPCM.append(frame) }
            let samples = decoder.decode(frame)
            if sampleCount == 0 {
                status("正在录音 · 松开麦克风键停止")
                log("已收到原生语音键开启后的真实音频。")
            }
            sampleCount += samples.count
            if testingEnabled { pcm.append(contentsOf: samples) }
            if bridgingEnabled { decodedSamples(samples) }
            let peak = samples.map { abs(Double($0)) }.max() ?? 0
            meter(Double(sampleCount) / 16_000, peak / 32768)
            if sampleCount >= 960_000 { finish("已达到单次 60 秒测试上限"); return }
        }
    }
    func finish(_ reason: String) {
        noAudioTimer?.invalidate(); voiceTimer?.invalidate()
        noAudioTimer = nil; voiceTimer = nil
        let active = requested || streaming
        if active, let caps { write(ATVVProtocol.microphoneClose(version: caps.version, sessionID: session)) }
        requested = false; streaming = false
        if active {
            voiceEnded()
            log("蓝牙音频统计：\(packetCount) 个通知，\(sampleCount) 个采样，未组成完整帧 \(accumulator.pending.count) 字节，最大接收间隔 \(Int(maxReceiveGap * 1000)) ms。")
        }
        accumulator.reset(); sync = nil
        if !pcm.isEmpty {
            do {
                guard let diagnostics else { throw PrivateFiles.error("私有录音目录不可用。") }
                let metadata: [String: Any] = ["sampleRate":16000,"frameBytes":caps?.frameSize ?? 120,"samples":sampleCount,"sync":diagnosticSync,"packets":packetCount,"maximumReceiveGapMS":maxReceiveGap * 1000]
                let url = try diagnostics.saveRecording(wave: WaveFile.encode(pcm), compressed: diagnosticADPCM,
                    metadata: JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted,.sortedKeys]))
                log("录音已保存：\(url.lastPathComponent)，\(String(format: "%.2f", Double(pcm.count) / 16000)) 秒；7 天后自动清理。")
                saved(url)
            } catch { log("录音保存失败：\(error.localizedDescription)") }
        }
        pcm = []; sampleCount = 0; diagnosticADPCM = Data(); diagnosticSync = []
        if active { log(reason); status(ready ? "语音通道就绪 · 已停止录音" : "语音已停止") }
        meter(0, 0)
    }
}
