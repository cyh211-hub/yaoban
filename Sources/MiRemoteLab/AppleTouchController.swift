import Foundation
import Darwin

// Private MultitouchSupport stays in a child process. Only the selected runtime
// may consume its bounded coordinate stream; the child never posts input.
final class AppleTouchController {
    var tap: (Int) -> Void = { _ in }
    var changed: () -> Void = {}
    var move: (RemoteTouchMotion.Delta) -> Void = { _ in }
    private var eventConsumerInstalled = false
    var event: (RemoteTouchMotion.Event) -> Void = { _ in } {
        didSet { eventConsumerInstalled = true }
    }
    private(set) var status = "已关闭"
    private var process: Process?
    private var parentPipe: Pipe?
    private var reader: DispatchSourceRead?
    private var generation = UUID()
    private var attempted = false
    private var retryAt: Double?
    private var ready = false
    private var buffer = Data()
    private var motion = RemoteTouchMotion()
    private enum Command { case tap(Int), swipe(RemoteTouchMotion.Direction) }
    private var commands: [(command: Command, due: Double)] = []
    static let circularKeys: Set<UInt16> = [0x28,0x52,0x51,0x50,0x4F]
    private var taps = RemoteTouchTap()
    private var physicalHeld = false
    private var touchGuardUntil = 0.0
    private var lastStreamTime: Double?
    private var lastFrameTime: Double?
    private var settings = RemoteTouchSettings()

    func start(deviceID: UUID, settings: RemoteTouchSettings) {
        if self.settings != settings { self.settings = settings; motion.reset(); taps.reset(); commands.removeAll() }
        guard process == nil else { return }
        if attempted {
            guard let retryAt, ProcessInfo.processInfo.systemUptime >= retryAt else { return }
            attempted = false; self.retryAt = nil
        }
        attempted = true; motion.reset(); taps.reset(); commands.removeAll(); lastFrameTime = nil; lastStreamTime = nil; ready = false; buffer.removeAll()
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/YaobanTouch")
        guard FileManager.default.isExecutableFile(atPath:binary.path) else { fail("触控组件缺失，请重新安装"); return }
        let task = Process(), input = Pipe(), output = Pipe(), token = UUID()
        generation = token
        task.executableURL = binary; task.arguments = ["--stream",deviceID.uuidString]
        task.standardInput = input; task.standardOutput = output; task.standardError = FileHandle.nullDevice
        let handle = output.fileHandleForReading, fd = handle.fileDescriptor
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor:fd,queue:.main)
        source.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            var bytes = [UInt8](repeating:0,count:4096)
            let count = read(fd,&bytes,bytes.count)
            if count > 0 { self.receive(Data(bytes.prefix(count))) }
            else if count == 0 { self.interrupted() }
            else if errno != EAGAIN && errno != EINTR { self.fail("触控通道中断，请重新检测") }
        }
        source.setCancelHandler { try? handle.close() }
        task.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.reader?.cancel(); self.reader = nil; self.parentPipe = nil; self.process = nil
                self.motion.reset(); self.taps.reset(); self.commands.removeAll(); self.ready = false
                self.retryAt = ProcessInfo.processInfo.systemUptime + 15
                self.setStatus("触控连接中断，正在恢复…")
            }
        }
        process = task; parentPipe = input; reader = source; source.resume()
        do { try task.run(); try? output.fileHandleForWriting.close(); setStatus("正在连接圆盘…") }
        catch { fail("触控组件启动失败，请重新检测") }
        DispatchQueue.main.asyncAfter(deadline:.now()+4) { [weak self] in
            guard let self, self.generation == token, self.process != nil, !self.ready else { return }
            self.fail("触控未就绪，请重新检测")
        }
    }
    private func receive(_ data:Data) {
        buffer.append(data)
        guard buffer.count <= 8192 else { fail("触控数据异常，已停止"); return }
        while let end = buffer.firstIndex(of:10) {
            let line = buffer.prefix(upTo:end); buffer.removeSubrange(...end)
            guard line.count <= 200, let text = String(data:line,encoding:.utf8), let message = RemoteTouchMessage.parse(text) else { fail("触控数据异常，已停止"); return }
            if message == .ready { ready = true; motion.reset(); taps.reset(); commands.removeAll(); lastFrameTime = nil; lastStreamTime = nil; setStatus("等待触控输入"); continue }
            guard ready else { continue }
            let now = ProcessInfo.processInfo.systemUptime, time: Double
            switch message { case .reset(let value), .cancel(let value), .contact(let value,_,_,_,_): time = value; case .ready: continue }
            guard now-time >= -0.02, now-time <= 0.15, lastStreamTime.map({ time > $0 }) ?? true else {
                motion.reset(); taps.reset(); commands.removeAll(); setStatus("触控延迟，等待新手势"); continue
            }
            lastStreamTime = time; lastFrameTime = now; setStatus("圆盘已就绪")
            guard !physicalHeld, now >= touchGuardUntil else { motion.reset(); taps.reset(); commands.removeAll(); continue }
            if case .cancel = message { commands.removeAll() }
            for count in taps.receive(message,now:now,maxTapCount:settings.maximumConfiguredTapCount,interval:settings.tapInterval) { enqueue(.tap(count),now:now) }
            let mode: RemoteTouchMotion.Configuration.Mode
            switch settings.mode {
            case .off: mode = .off
            case .pointer: mode = .pointer
            case .scroll: mode = .scroll
            case .swipe: mode = .swipe
            case .hybrid: mode = .hybrid
            }
            let configuration = RemoteTouchMotion.Configuration(
                mode:mode, maximumPointerSpeed:settings.maximumPointerSpeed,
                maximumScrollSpeed:settings.maximumScrollSpeed, acceleration:settings.acceleration,
                ringStartRadius:settings.ringStartRadius, swipeDistance:settings.swipeDistance)
            for output in motion.receive(message,now:now,configuration:configuration) {
                if case .swipe(let direction) = output { enqueue(.swipe(direction),now:now) }
                else {
                    event(output)
                    if !eventConsumerInstalled, case .motion(let delta,_) = output { move(delta) }
                }
            }
        }
        if buffer.count > 200 { fail("触控数据异常，已停止") }
    }
    func notePhysicalKeys(_ keys: Set<UInt16>, now: Double = ProcessInfo.processInfo.systemUptime) {
        physicalHeld = !keys.isDisjoint(with:Self.circularKeys)
        if physicalHeld { motion.reset(); taps.reset(); commands.removeAll(); touchGuardUntil = now + 0.2 }
    }
    func tick(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard ready, !physicalHeld, now >= touchGuardUntil else { return }
        for count in taps.tick(now:now) { enqueue(.tap(count),now:now) }
        let due = commands.filter { now >= $0.due }
        commands.removeAll { now >= $0.due }
        for item in due where now-item.due <= 0.15 {
            switch item.command { case .tap(let count): tap(count); case .swipe(let direction): event(.swipe(direction)) }
        }
        if let lastFrameTime, now-lastFrameTime > 15 { setStatus("等待触控唤醒") }
    }
    private func enqueue(_ command: Command, now: Double) {
        // HID and touch arrive on separate channels. Give a circular-button
        // edge one bounded arbitration interval to cancel its incidental touch.
        guard commands.count < 8 else { commands.removeAll(); taps.reset(); motion.reset(); return }
        commands.append((command,now+0.08))
    }
    // Temporary source compatibility for v0.9 callers; remove after RemoteRuntime adopts events.
    func start(deviceID:UUID,speed:Double) {
        start(deviceID:deviceID,settings:RemoteTouchSettings(mode:.pointer,speed:speed))
    }
    private func setStatus(_ text:String) {
        guard status != text else { return }; status = text; changed()
    }
    private func interrupted() {
        // EOF invalidates pending gestures before the later Process callback.
        stop(retryAfter: 15)
        setStatus("触控连接中断，正在恢复…")
    }
    private func fail(_ message:String) {
        // Every transient helper failure gets a bounded retry. Previously fail()
        // left attempted=true with no retryAt, which disabled automatic recovery.
        stop(retryAfter: 15)
        setStatus(message)
    }
    private func stop(retryAfter delay: Double?) {
        let oldProcess = process
        generation = UUID(); ready = false; physicalHeld = false; touchGuardUntil = 0; motion.reset(); taps.reset(); commands.removeAll(); lastFrameTime = nil; lastStreamTime = nil; buffer.removeAll()
        reader?.cancel(); reader = nil
        try? parentPipe?.fileHandleForWriting.close(); parentPipe = nil
        if let task = oldProcess {
            // EOF requests orderly private-client cleanup. Bound termination if it hangs.
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { if task.isRunning { task.terminate() } }
        }
        process = nil
        // MTDeviceStop in the old helper can arrive after the parent has closed
        // its pipe. Do not attach a replacement helper until that cleanup has
        // completed, otherwise the old stop can silence the new registration.
        if let delay {
            attempted = true
            retryAt = ProcessInfo.processInfo.systemUptime + max(delay, oldProcess == nil ? 0 : 1.25)
        } else if oldProcess != nil {
            attempted = true
            retryAt = ProcessInfo.processInfo.systemUptime + 1.25
        } else {
            attempted = false
            retryAt = nil
        }
        setStatus("已关闭")
    }
    func stop() { stop(retryAfter:nil) }
    deinit { stop() }
}
