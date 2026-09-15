// GPL-3.0. Unprivileged, bounded audio consumer. Raw Bluetooth lines are never logged.
import Foundation
import Darwin

struct VoiceInputDiagnostics: Encodable {
    var bytesRead = 0
    var readChunks = 0
    var completeLines = 0
    var invalidUTF8Lines = 0
    var oversizedLines = 0
    var oversizedBufferStops = 0
    var unprocessedBytesAtStop = 0
    var trailingIncompleteLines = 0
    var trailingIncompleteBytes = 0
}
struct VoiceDiagnostics: Encodable {
    let input: VoiceInputDiagnostics
    let transport: AppleVoiceTransport.Diagnostics
    let timing: AppleVoiceTimingDiagnostics
    let wire: AppleVoiceWireDiagnostics
    var packetLog: AppleVoicePacketLog.Diagnostics? = nil
    var addressed: AppleVoiceAddressedCapture.Diagnostics? = nil
}

func exclusiveWrite(_ data: Data, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw BoundApple.Failure.unavailable }
    defer { close(fd) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < data.count {
            let n = write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw BoundApple.Failure.unavailable }
            offset += n
        }
    }
}
func waitForStart(in output: URL) throws {
    let signal = output.appendingPathComponent("start.signal")
    let deadline = ProcessInfo.processInfo.systemUptime + 60
    while ProcessInfo.processInfo.systemUptime < deadline {
        var info = stat()
        if lstat(signal.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_mode & 0o777 == 0o600, info.st_size == 0 else {
                throw BoundApple.Failure.unavailable
            }
            return
        }
        guard errno == ENOENT else { throw BoundApple.Failure.unavailable }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw BoundApple.Failure.unavailable
}
func wav(_ samples: [Int16]) -> Data {
    var data = Data()
    func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    data.append(contentsOf: "RIFF".utf8); u32(UInt32(samples.count * 2 + 36))
    data.append(contentsOf: "WAVEfmt ".utf8); u32(16); u16(1); u16(1)
    u32(48000); u32(96000); u16(2); u16(16)
    data.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
    for sample in samples { u16(UInt16(bitPattern: sample)) }
    return data
}

do {
    guard getuid() != 0 else { throw BoundApple.Failure.unavailable }
    let bound = try BoundApple.resolve()
    if CommandLine.arguments == [CommandLine.arguments[0], "--identity"] {
        FileHandle.standardOutput.write(try JSONEncoder().encode(bound)); print("")
        exit(0)
    }
    if CommandLine.arguments.count == 2,
       ["--inspect-mic-activation", "--activate-mic-once"].contains(CommandLine.arguments[1]) {
        let outcome = try AppleVoiceActivationProbe.run(bound: bound,
            inspectOnly: CommandLine.arguments[1] == "--inspect-mic-activation")
        FileHandle.standardOutput.write(try JSONEncoder().encode(outcome)); print("")
        exit(0)
    }
    guard CommandLine.arguments.count == 3,
          ["--consume", "--consume-pklg", "--consume-addressed"].contains(CommandLine.arguments[1]) else { exit(2) }
    let binary = CommandLine.arguments[1] == "--consume-pklg"
    let addressedMode = CommandLine.arguments[1] == "--consume-addressed"
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
          (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { exit(2) }
    let expected = try JSONDecoder().decode(BoundApple.self, from: Data(contentsOf: output.appendingPathComponent("expected-device.json")))
    guard expected.id == bound.id, expected.identity == bound.identity, expected.address == bound.address else { exit(2) }
    let decoder = try AppleVoiceDecoder()
    var buffer = Data(), pcm: [Int16] = []
    var inputDiagnostics = VoiceInputDiagnostics()
    var reports = 0, errors = 0, resets = 0
    guard fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK) == 0 else { exit(2) }
    // The supervisor must see this acknowledgment before it says capture is
    // ready. Authorization and preparation never consume the audio time budget.
    let ready = try JSONSerialization.data(withJSONObject: ["status": "ready", "capturing": false])
    try exclusiveWrite(ready, to: output.appendingPathComponent("consumer-ready.json"))
    try waitForStart(in: output)
    let current = try BoundApple.resolve()
    guard current.id == bound.id, current.identity == bound.identity,
          current.address == bound.address else { throw BoundApple.Failure.unavailable }
    let started = ProcessInfo.processInfo.systemUptime
    let clock = AppleVoiceSessionClock(startedAt: Date(), monotonicStart: started)
    var transport = AppleVoiceTransport(address: bound.address, sessionStartedAt: clock.startedAt)
    var addressed = addressedMode ? AppleVoiceAddressedCapture(address: bound.address, startedAt: started) : nil
    var packetLog = binary ? AppleVoicePacketLog(address: bound.address, startedAt: started) : nil
    let listening = try JSONSerialization.data(withJSONObject: ["status": "listening"])
    try exclusiveWrite(listening, to: output.appendingPathComponent("consumer-started.json"))
    var binaryReady = false
    var lastIdentity = started
    var reason = "eof"
    var running = true
    while running {
        let now = ProcessInfo.processInfo.systemUptime
        if now - started >= 23 { reason = "consumer-timeout"; break }
        if now - lastIdentity >= 0.5 {
            guard let current = try? BoundApple.resolve(), current.id == bound.id,
                  current.identity == bound.identity, current.address == bound.address else { reason = "device-changed-or-disconnected"; break }
            lastIdentity = now
        }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready < 0 && errno == EINTR { continue }
        // Darwin FIFO polling may return a timeout after the last writer closes.
        // A nonblocking read still distinguishes EAGAIN from EOF; check it even
        // after poll times out, so the consumer does not wait for its outer limit.
        var chunk = [UInt8](repeating: 0, count: 4096)
        let size = read(STDIN_FILENO, &chunk, chunk.count)
        if size == 0 { break }
        if size < 0 { if errno == EAGAIN || errno == EINTR { continue }; reason = "read-failure"; break }
        inputDiagnostics.bytesRead += size
        inputDiagnostics.readChunks += 1
        guard let receivedAt = clock.date(at: ProcessInfo.processInfo.systemUptime) else {
            reason = "consumer-timeout"; break
        }
        if binary {
            let events = packetLog!.receive(Data(chunk.prefix(size)), now: ProcessInfo.processInfo.systemUptime)
            if !binaryReady, packetLog!.diagnostics.selectedConnections > 0, !packetLog!.stopped {
                try exclusiveWrite(Data("{\"status\":\"selected-device-ready\"}".utf8),
                                   to: output.appendingPathComponent("binary-stream-ready.json"))
                binaryReady = true
            }
            for event in events {
                do {
                    switch event {
                    case .reset: try decoder.reset(); resets += 1
                    case let .report(data, newStream):
                        if newStream { try decoder.reset(); resets += 1 }
                        reports += 1
                        let samples = try decoder.consume(reportID: 0xFA, payload: data)
                        guard pcm.count + samples.count <= 960000 else {
                            reason = "audio-limit"; running = false; break
                        }
                        pcm += samples
                    }
                } catch { errors += 1; try? decoder.reset() }
                if !running { break }
            }
            if packetLog!.stopped {
                reason = packetLog!.diagnostics.disconnects > 0 ? "device-changed-or-disconnected" : "invalid-packet-log"
                running = false
            }
            continue
        }
        buffer.append(contentsOf: chunk.prefix(size))
        guard buffer.count <= 16384 else {
            inputDiagnostics.oversizedBufferStops += 1; reason = "oversized-line"; break
        }
        while let end = buffer.firstIndex(of: 10) {
            let bytes = buffer.prefix(upTo: end)
            inputDiagnostics.completeLines += 1
            if bytes.count > 8192 { inputDiagnostics.oversizedLines += 1 }
            let line = String(data: bytes, encoding: .utf8)
            buffer.removeSubrange(...end)
            guard let line else { inputDiagnostics.invalidUTF8Lines += 1; continue }
            let event: AppleVoiceTransport.Event?
            if addressedMode {
                event = addressed!.receive(line, now: ProcessInfo.processInfo.systemUptime)
                if !binaryReady, addressed!.diagnostics.selectedAddressRecords > 0, !addressed!.stopped {
                    try exclusiveWrite(Data("{\"status\":\"selected-device-ready\"}".utf8),
                                       to: output.appendingPathComponent("binary-stream-ready.json"))
                    binaryReady = true
                }
                if addressed!.stopped { reason = "addressed-capture-stopped"; running = false }
            } else { event = transport.receive(line, now: receivedAt) }
            guard let event else { continue }
            do {
                switch event {
                case .reset: try decoder.reset(); resets += 1
                case let .report(data, newStream):
                    if newStream { try decoder.reset(); resets += 1 }
                    reports += 1
                    let samples = try decoder.consume(reportID: 0xFA, payload: data)
                    guard pcm.count + samples.count <= 960000 else { reason = "audio-limit"; running = false; break }
                    pcm += samples
                }
            } catch { errors += 1; try? decoder.reset() }
        }
    }
    // A final unterminated fragment is counted, never parsed as a packet. This
    // also distinguishes an upstream cutoff from a clean stream with no lines.
    inputDiagnostics.unprocessedBytesAtStop = buffer.count
    if let newline = buffer.lastIndex(of: 10) {
        inputDiagnostics.trailingIncompleteBytes = buffer.distance(from: buffer.index(after: newline), to: buffer.endIndex)
    } else { inputDiagnostics.trailingIncompleteBytes = buffer.count }
    if inputDiagnostics.trailingIncompleteBytes > 0 { inputDiagnostics.trailingIncompleteLines = 1 }
    packetLog?.finish()
    if !pcm.isEmpty { try exclusiveWrite(wav(pcm), to: output.appendingPathComponent("apple-voice.wav")) }
    let rms = pcm.isEmpty ? 0 : sqrt(pcm.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(pcm.count))
    let diagnostics = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
        VoiceDiagnostics(input: inputDiagnostics, transport: transport.diagnostics,
                         timing: transport.timingDiagnostics, wire: addressed?.wireDiagnostics ?? transport.wireDiagnostics,
                         packetLog: packetLog?.diagnostics, addressed: addressed?.diagnostics)))
    let summary: [String: Any] = ["reports": reports, "samples": pcm.count, "seconds": Double(pcm.count) / 48000,
        "decodeErrors": errors, "streamResets": resets, "rms": rms, "stopped": reason, "rawTraceSaved": false,
        "diagnostics": diagnostics]
    let encoded = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    try exclusiveWrite(encoded, to: output.appendingPathComponent("summary.json"))
    FileHandle.standardOutput.write(encoded); print("")
} catch {
    let reason = (error as? BoundApple.Failure)?.rawValue ?? "initializationFailed"
    fputs("voice-check: \(reason)\n", stderr)
    exit(2)
}
