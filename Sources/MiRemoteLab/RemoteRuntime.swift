import AppKit

// Only this context owns a physical device. The editor never owns the service.
final class RemoteRuntime {
    let id: UUID
    let hid = HIDProbe()
    let appleHID = AppleHIDProbe()
    let appleMedia = AppleMediaKeySuppressor()
    let touch = AppleTouchController()
    let appleVoice = AppleVoiceController()
    private var appleMicReady = false
    private var appleMicSession = false
    var isApple: Bool { record.binding.model == .apple }
    var connected: Bool { isApple ? appleHID.isConnected : hid.isConnected }
    private var nextDisplayCheck: TimeInterval = 0
    private var displayConnected = false
    var connectionForDisplay: Bool {
        guard isApple, !connected else { return connected }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextDisplayCheck {
            nextDisplayCheck = now + 2
            displayConnected = (try? BoundApple.resolve().identity) == record.binding.hidIdentity
        }
        return displayConnected
    }
    var systemName: String? { isApple ? appleHID.systemName : hid.systemName }
    var selectedForInput = false
    var battery: RemoteBatteryReading { isApple ? appleHID.batteryReading : ble.batteryReading }
    let ble = BLEProbe()
    let engine = RemoteActionEngine()
    let mapper: DeviceMapper
    var record: SavedRemote
    var log: (String) -> Void = { _ in }
    var changed: () -> Void = {}
    var keysChanged: (Set<UInt16>,Set<UInt16>) -> Void = { _,_ in }
    var canRecordVoice: () -> Bool = { true }
    private let emitter: KeyboardEmitter
    private let outputOwners: RemoteOutputOwnership
    private let gestureOwner = UUID()
    private let voiceOwners: RemoteVoiceOwnership
    private let systemMic: SystemMicrophone
    private(set) var physicalKeys = Set<UInt16>()
    private var ignoredMicPress = false
    private var microphoneRouted = false
    private var software: [UInt16:[UInt16]] = [:]
    private var longBindings: [UInt16:[UInt16]] = [:]
    private(set) var mappingStatus = "尚未启用"
    private(set) var keyStatus = "等待连接"
    private(set) var voiceStatus = "等待连接"
    private(set) var running = false
    private(set) var restoreFailure: String?
    var microphoneEnabled = true { didSet {
        ble.bridgingEnabled = microphoneEnabled
        if isApple {
            if !microphoneEnabled { appleVoice.stop(); release(blocking: physicalKeys) }
            else if running { appleVoice.prepare() }
        }
    } }
    var voiceReady: Bool { isApple ? appleVoice.prepared : ble.voiceReady }
    init(record: SavedRemote, directory: URL, emitter: KeyboardEmitter,
         outputOwners: RemoteOutputOwnership, voiceOwners: RemoteVoiceOwnership, systemMic: SystemMicrophone) {
        self.id = record.id; self.record = record; self.emitter = emitter
        self.outputOwners = outputOwners; self.voiceOwners = voiceOwners; self.systemMic = systemMic
        mapper = DeviceMapper(journalURL:directory.appendingPathComponent("mapping-restore-\(record.id.uuidString).json"))
        touch.changed = { [weak self] in
            guard let self else { return }; self.log("触控：" + self.touch.status); self.changed()
        }
        touch.tap = { [weak self] count in
            guard let gesture = RemoteTouchGesture.tap(count) else { return }; self?.sendTouchGesture(gesture)
        }
        touch.event = { [weak self] event in
            guard let self, self.running, self.selectedForInput, self.record.enabled, self.isApple, self.connected,
                  self.canRecordVoice(), self.record.configuration.touch.mode != .off else { return }
            switch event {
            case .motion(let delta, let output):
                self.emitter.movePointer(x:delta.x,y:delta.y,scroll:output == .scroll)
            case .swipe(let direction):
                let gesture: RemoteTouchGesture
                switch direction { case .up: gesture = .swipeUp; case .down: gesture = .swipeDown; case .left: gesture = .swipeLeft; case .right: gesture = .swipeRight }
                self.sendTouchGesture(gesture)
            }
        }
        appleVoice.changed = { [weak self] in
            guard let self else { return }
            if self.voiceStatus != self.appleVoice.status { self.log("苹果语音：" + self.appleVoice.status) }
            self.voiceStatus = self.appleVoice.status; self.changed()
        }
        appleVoice.began = { [weak self] in
            guard let self, self.running, self.selectedForInput, self.microphoneEnabled,
                  self.physicalKeys.contains(0x3E), self.voiceOwners.owner == self.id,
                  self.canRecordVoice(), self.appleMicSession else { self?.appleVoice.finish(); return }
            guard self.systemMic.begin(sampleRate: .pcm48k) else { self.appleVoice.finish(); return }
            self.appleMicReady = true
            self.applyKeys(self.physicalKeys)
        }
        appleVoice.samples = { [weak self] samples in
            guard let self, self.appleMicReady, self.voiceOwners.owner == self.id else { return }
            self.systemMic.append(samples)
        }
        appleVoice.ended = { [weak self] in
            guard let self else { return }
            self.appleMicReady = false; self.appleMicSession = false
            // A timeout/disconnect while physically held must release the mapped
            // keyboard modifier immediately and block it until physical release.
            if self.physicalKeys.contains(0x3E) { self.engine.releaseAll(blocking: self.physicalKeys) }
            if self.voiceOwners.release(self.id) { self.systemMic.finish() }
        }
        appleHID.targetIdentity = record.binding.hidIdentity
        appleHID.log = { [weak self] in self?.log($0) }
        appleMedia.log = { [weak self] in self?.log($0) }
        appleHID.onMediaEdge = { [weak self] button,down,time in
            self?.appleMedia.note(button:button,down:down,timestamp:time)
        }
        appleHID.batteryChanged = { [weak self] in self?.changed() }
        appleHID.status = { [weak self] in self?.keyStatus = $0; self?.changed() }
        appleHID.onKeys = { [weak self] old,next in self?.receive(old:old,next:next) }
        appleHID.onConnect = { [weak self] in
            self?.refresh(); if self?.microphoneEnabled == true { self?.appleVoice.prepare() }
        }
        appleHID.onDisconnect = { [weak self] in self?.appleMedia.stop(); self?.appleVoice.stop(); self?.release(); self?.physicalKeys = []; self?.refresh() }
        hid.targetIdentity = record.binding.hidIdentity; mapper.targetIdentity = record.binding.hidIdentity; ble.binding = record.binding
        hid.log = { [weak self] in self?.log($0) }; ble.log = hid.log; mapper.log = hid.log
        hid.status = { [weak self] in self?.keyStatus = $0; self?.changed() }
        ble.status = { [weak self] in self?.voiceStatus = $0; self?.changed() }
        ble.batteryChanged = { [weak self] in self?.changed() }
        ble.hidConnected = { [weak self] in self?.running == true && self?.hid.isConnected == true }
        hid.onConnect = { [weak self] in self?.refresh(); self?.ble.ensureConnection() }
        hid.onDisconnect = { [weak self] in
            guard let self else { return }
            self.release(); self.physicalKeys = []; self.mapper.invalidateConnection()
            self.ble.systemDisconnected(); self.refresh()
        }
        hid.onKeys = { [weak self] old,next in self?.receive(old:old,next:next) }
        engine.emit = { [weak self] key,down in
            guard let self else { return }; self.outputOwners.send(owner:self.id,key:key,down:down)
        }
        engine.repeatKey = { [weak self] in self?.emitter.repeatKey($0) }
        ble.voiceStarted = { [weak self] in
            guard let self, self.voiceOwners.owner == self.id, self.microphoneEnabled else { return }; self.systemMic.begin()
        }
        ble.decodedSamples = { [weak self] samples in
            guard let self, self.voiceOwners.owner == self.id else { return }; self.systemMic.append(samples)
        }
        ble.voiceEnded = { [weak self] in
            guard let self, self.voiceOwners.owner == self.id else { return }; self.systemMic.finish()
        }
    }
    func start() {
        guard selectedForInput, record.binding.isBound, record.enabled, record.binding.model.supported, !running else { return }
        running = true
        if isApple { voiceStatus = appleVoice.status; appleHID.start(); if microphoneEnabled { appleVoice.prepare() } }
        else { hid.start(requestPermission:false); ble.start() }
        refresh()
    }
    func refresh() {
        guard running else { changed(); return }
        guard physicalKeys.isEmpty else { return }
        let plan = MappingPlan(configuration:record.configuration)
        do {
            // A stale event-system entry is not evidence of a live remote.
            guard connected else {
                software = [:]; longBindings = [:]; setStatus("等待遥控器连接"); return
            }
            let present = isApple ? appleHID.isConnected : try mapper.apply(plan.native)
            let needsOutput = !plan.software.isEmpty || !plan.longPress.isEmpty || (isApple && record.configuration.touch.mode != .off)
            let mediaReady = !isApple || appleMedia.start(ids:appleHID.seizedRegistryIDs,configuration:record.configuration)
            let ready = present && mediaReady && (!needsOutput || emitter.start())
            software = ready ? plan.software : [:]; longBindings = ready ? plan.longPress : [:]
            setStatus(ready ? "映射已就绪 · 按当前操作方式执行" : appleMedia.failure ?? emitter.failure ?? "等待输入监控与辅助功能权限")
            syncTouch()
            if isApple && microphoneEnabled { appleVoice.prepare() }
        } catch { release(blocking:physicalKeys); setStatus(error.localizedDescription) }
    }
    private func setStatus(_ text: String) {
        if mappingStatus != text { mappingStatus = text; log("映射：" + text) }
        changed()
    }
    private func receive(old: Set<UInt16>, next: Set<UInt16>) {
        guard running else { return }
        physicalKeys = next
        if isApple { touch.notePhysicalKeys(next) }
        keysChanged(old,next)
        if (!isApple || (microphoneEnabled && appleVoice.installed)), !old.contains(0x3E), next.contains(0x3E) {
            ignoredMicPress = !canRecordVoice() || !voiceOwners.acquire(id)
            if isApple && !ignoredMicPress {
                if appleVoice.prepared {
                    appleMicSession = true; appleMicReady = false; appleVoice.start()
                } else {
                    ignoredMicPress = true; _ = voiceOwners.release(id)
                    appleVoice.prepare()
                }
            }
            if ignoredMicPress { log("另一只遥控器正在收音或快捷键正在录入，本次语音键未执行。") }
        }
        applyKeys(next)
        syncVoice()
        if !next.contains(0x3E) {
            ignoredMicPress = false
            if isApple && appleMicSession { appleVoice.finish() }
            else if voiceOwners.release(id) { systemMic.finish() }
        }
        if next.isEmpty { refresh() }
    }
    private func applyKeys(_ next: Set<UInt16>) {
        let waitingForApple = isApple && appleMicSession && !appleMicReady
        let routedKeys = (ignoredMicPress || waitingForApple) ? next.subtracting([0x3E]) : next
        let config = record.configuration
        engine.update(routedKeys, bindings: software, repeatEnabled: config.repeatEnabled,
                      triggers: config.triggers, longBindings: longBindings, longPressDelay: config.longPressDelay)
    }
    func tick() {
        guard running else { return }
        if isApple {
            appleHID.checkConnection(); appleMedia.checkHealth()
            if microphoneEnabled && connected { appleVoice.tick() }
        }
        syncTouch()
        touch.tick(); engine.tick(); syncVoice()
    }
    private func sendTouchGesture(_ gesture: RemoteTouchGesture) {
        guard running, selectedForInput, record.enabled, isApple, connected, physicalKeys.isDisjoint(with:AppleTouchController.circularKeys),
              canRecordVoice(), record.configuration.touch.mode != .off else { return }
        let config = record.configuration
        let keys = config.touch.binding(for:gesture) ?? gesture.legacySource.flatMap { config.bindings[$0] } ?? []
        for key in keys { outputOwners.send(owner:gestureOwner,key:key,down:true) }
        for key in keys.reversed() { outputOwners.send(owner:gestureOwner,key:key,down:false) }
    }
    func syncVoice() {
        let allowed = !isApple && running && engine.microphoneHeld && voiceOwners.owner == id && canRecordVoice()
        guard microphoneRouted != allowed else { return }
        microphoneRouted = allowed; ble.microphoneChanged(down:allowed)
    }
    private func syncTouch() {
        guard running, selectedForInput, record.enabled, isApple, connected, emitter.isRunning,
              canRecordVoice(), record.configuration.touch.mode != .off else { touch.stop(); return }
        touch.start(deviceID:id,settings:record.configuration.touch)
        touch.notePhysicalKeys(physicalKeys)
    }
    func release(blocking: Set<UInt16> = []) {
        touch.stop()
        appleVoice.stop(); appleMicReady = false; appleMicSession = false
        engine.releaseAll(blocking:blocking)
        outputOwners.release(id)
        outputOwners.release(gestureOwner)
        software = [:]; longBindings = [:]; microphoneRouted = false
        ble.microphoneChanged(down:false)
        if voiceOwners.release(id) { systemMic.finish() }
    }
    func update(_ value: SavedRemote) {
        release(blocking:physicalKeys); record = value; refresh()
    }
    func stop() {
        running = false; appleMedia.stop(); release(); physicalKeys = []; hid.stop(); appleHID.stop(); ble.stop()
        do { try mapper.restore(); restoreFailure = nil }
        catch { restoreFailure = error.localizedDescription; log("恢复失败，记录保留：\(error.localizedDescription)") }
        keyStatus = "已暂停"; voiceStatus = "已暂停"; setStatus("设备已停用")
    }
}
