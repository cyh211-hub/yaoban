import Foundation
import Darwin

// Main-thread lifecycle; socket parsing/decoder and bounded auxiliary activation
// stay off the UI thread. No microphone fallback, raw log or permanent WAV.
final class AppleVoiceController {
    #if YAOBAN_VOICE_TESTS
    static var socketPath = ""
    static var testActivation: () throws -> Void = {}
    private let expectedPeer = getuid()
    #else
    static let socketPath = "/var/run/yaoban-apple-voice/control.sock"
    private let expectedPeer: uid_t = 0
    #endif
    var changed: () -> Void = {}
    var began: () -> Void = {}
    var samples: ([Int16]) -> Void = { _ in }
    var ended: () -> Void = {}
    private(set) var status = "苹果语音未启用 · 需安装 PacketLogger"
    private(set) var prepared = false
    private var generation = UUID()
    private var warming = false
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var connectionTicket = UUID()
    private var releaseRequested = false
    private var activation: Process?
    private var prepareRetryAt: TimeInterval = 0
    var installed: Bool { FileManager.default.fileExists(atPath: Self.socketPath) }

    func prepare(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard installed, !prepared, !warming, now >= prepareRetryAt else { return }
        prepareRetryAt = now + 20
        warming = true; setStatus("正在准备苹果语音通道…")
        launch(warm: true)
    }
    func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if !prepared && !warming { prepare(now: now) }
    }
    func start() {
        guard installed, prepared else { setStatus("语音通道尚未就绪"); return }
        stopConnection(); setStatus("正在开启苹果麦克风…")
        launch(warm: false)
    }
    func finish() {
        let ticket = generation
        lock.lock(); releaseRequested = true
        if let task = activation, task.isRunning { kill(task.processIdentifier, SIGKILL) }
        let waitingForConnection = descriptor < 0
        lock.unlock()
        if waitingForConnection {
            // Release can arrive before the background worker has connected.
            // Cancel its ticket now; a later connect must not start a 63 s capture.
            stopConnection(); setStatus("苹果语音已就绪"); ended(); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.lock.lock(); let fd = self.descriptor; self.lock.unlock()
            if fd >= 0 { _ = shutdown(fd, SHUT_WR) }
        }
    }
    func stop() {
        stopConnection(); prepared = false; warming = false; prepareRetryAt = 0
        setStatus(installed ? "苹果语音已暂停" : "苹果语音未启用 · 需安装 PacketLogger")
    }
    private func stopConnection() {
        generation = UUID()
        lock.lock(); connectionTicket = UUID(); releaseRequested = true
        if let task = activation, task.isRunning { kill(task.processIdentifier, SIGKILL) }
        let fd = descriptor; descriptor = -1; lock.unlock()
        if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) } // worker owns the close
    }
    private func setStatus(_ text: String) { status = text; changed() }
    private func launch(warm: Bool) {
        let ticket = UUID(); generation = ticket
        lock.lock(); connectionTicket = ticket; releaseRequested = false; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var socketFD: Int32 = -1
            do {
                let bound = try BoundApple.resolve()
                socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
                guard socketFD >= 0 else { throw Failure.unavailable }
                _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)
                var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                let bytes = Array(Self.socketPath.utf8CString)
                withUnsafeMutableBytes(of: &address.sun_path) { target in
                    target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
                }
                var timeout = timeval(tv_sec: 1, tv_usec: 0), yes: Int32 = 1
                _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, 4)
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard connected == 0 else { throw Failure.unavailable }
                // Authenticate root ownership of the endpoint as well as its fixed path.
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(socketFD, &uid, &gid) == 0, uid == self.expectedPeer else { throw Failure.unavailable }
                self.lock.lock()
                let currentTicket = self.connectionTicket == ticket
                if currentTicket { self.descriptor = socketFD }
                self.lock.unlock()
                guard currentTicket else { throw Failure.unavailable }
                let command = Array((warm ? "WARM\n" : "CAPTURE\n").utf8)
                guard command.withUnsafeBytes({ write(socketFD, $0.baseAddress, $0.count) }) == command.count else { throw Failure.unavailable }
                let start = ProcessInfo.processInfo.systemUptime
                var parser = AppleVoiceAddressedCapture(address: bound.address, startedAt: start, duration: 65)!
                let decoder = try AppleVoiceDecoder()
                var buffer = Data(), textBuffer = Data(), active = false, lastIdentity = start
                var done = false, receivedAudio = false
                while !done && ProcessInfo.processInfo.systemUptime - start < (warm ? 18 : 65) {
                    self.lock.lock(); let valid = self.connectionTicket == ticket; self.lock.unlock()
                    guard valid else { throw Failure.unavailable }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastIdentity >= 0.5 {
                        let current = try BoundApple.resolve()
                        guard current.id == bound.id, current.identity == bound.identity, current.address == bound.address else { throw Failure.unavailable }
                        lastIdentity = now
                    }
                    var chunk = [UInt8](repeating: 0, count: 4096)
                    let count = read(socketFD, &chunk, chunk.count)
                    if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                    guard count > 0 else { throw Failure.unavailable }
                    buffer.append(contentsOf: chunk.prefix(count))
                    guard buffer.count <= 16384 else { throw Failure.unavailable }
                    while buffer.count >= 5 {
                        let kind = buffer[0]
                        let size = (1...4).reduce(0) { ($0 << 8) | Int(buffer[$1]) }
                        guard size <= 8192 else { throw Failure.unavailable }
                        guard buffer.count >= size + 5 else { break }
                        let payload = Data(buffer[5..<(5 + size)])
                        buffer = Data(buffer.dropFirst(5 + size))
                        if kind == 1 && !warm && !active {
                            try self.activate(ticket: ticket)
                            active = true
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.generation == ticket else { return }
                                self.setStatus("苹果麦克风已开启"); self.began()
                            }
                        } else if kind == 2 && !warm && active {
                            textBuffer.append(payload)
                            guard textBuffer.count <= 16384 else { throw Failure.unavailable }
                            while let end = textBuffer.firstIndex(of: 10) {
                                let rawLine = Data(textBuffer.prefix(upTo: end))
                                textBuffer = Data(textBuffer.dropFirst(end + 1))
                                guard rawLine.count <= 8192, let line = String(data: rawLine, encoding: .utf8) else { throw Failure.unavailable }
                                if let event = parser.receive(line, now: ProcessInfo.processInfo.systemUptime) {
                                    switch event {
                                    case .reset: try decoder.reset()
                                    case let .report(value, fresh):
                                        if fresh { try decoder.reset() }
                                        let samples = try decoder.consume(reportID: 0xFA, payload: value)
                                        if !samples.isEmpty {
                                            receivedAudio = true
                                            DispatchQueue.main.async { [weak self] in
                                                guard let self, self.generation == ticket else { return }; self.samples(samples)
                                            }
                                        }
                                    }
                                }
                                if parser.stopped { throw Failure.unavailable }
                            }
                        } else if kind == 3 {
                            guard let result = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                                  result["debugSettingsRestored"] as? Bool == true,
                                  result["rawTraceRemoved"] as? Bool == true,
                                  result["receivedData"] as? Bool == true else { throw Failure.unavailable }
                            done = true
                        } else { throw Failure.unavailable }
                    }
                }
                guard done else { throw Failure.unavailable }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.warming = false; self.prepared = true; self.prepareRetryAt = 0
                    self.setStatus(warm || receivedAudio ? "苹果语音已就绪" : "本次未收到苹果语音，请重试")
                    if !warm { self.ended() }
                }
            } catch {
                let cancelled = (error as? Failure) == .cancelled
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.warming = false
                    self.setStatus(cancelled ? "本次语音已取消" : "苹果收音暂不可用，正在自动恢复…")
                    if warm {
                        self.prepared = false
                        self.prepareRetryAt = ProcessInfo.processInfo.systemUptime + 5
                    } else { self.ended() }
                }
            }
            if socketFD >= 0 {
                self.lock.lock(); if self.descriptor == socketFD { self.descriptor = -1 }; self.lock.unlock()
                close(socketFD)
            }
        }
    }
    private enum Failure: Error, Equatable { case unavailable, cancelled }
    private func activate(ticket: UUID) throws {
        #if YAOBAN_VOICE_TESTS
        lock.lock(); let valid = connectionTicket == ticket && !releaseRequested; lock.unlock()
        guard valid else { throw Failure.cancelled }
        try Self.testActivation()
        return
        #else
        let task = Process()
        task.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/YaobanVoiceControl")
        task.arguments = ["--activate"]
        task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        lock.lock()
        guard connectionTicket == ticket, !releaseRequested else { lock.unlock(); throw Failure.cancelled }
        do { try task.run(); activation = task; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer { lock.lock(); if activation === task { activation = nil }; lock.unlock() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if task.isRunning { kill(task.processIdentifier, SIGKILL); task.waitUntilExit(); throw Failure.unavailable }
        guard task.terminationStatus == 0 else {
            lock.lock(); let cancelled = releaseRequested || connectionTicket != ticket; lock.unlock()
            throw cancelled ? Failure.cancelled : Failure.unavailable
        }
        #endif
    }
}
