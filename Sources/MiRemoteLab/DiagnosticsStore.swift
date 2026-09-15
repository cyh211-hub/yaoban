import Foundation
import Darwin

final class DiagnosticsStore {
    struct Policy {
        var logFileBytes = 1_048_576
        var logTotalBytes = 10_485_760
        var recordingTotalBytes = 20_971_520
        var maxAge: TimeInterval = 7 * 86400
        var linesPerSecond = 60
    }
    let directory: URL
    let policy: Policy
    private var handle: FileHandle?
    private var current: URL?
    private var bytes = 0
    private var rateSecond = -1.0
    private var rateCount = 0
    private var lastPrune = Date.distantPast
    init(directory: URL, policy: Policy = Policy()) throws {
        self.directory = directory; self.policy = policy
        try PrivateFiles.ensureDirectory(directory)
        try prune(now: Date())
    }
    deinit { try? handle?.close() }
    static func clean(_ text: String) -> String {
        String(text.prefix(1000)).replacingOccurrences(of: "\n", with: " ↵ ")
            .replacingOccurrences(of: "\r", with: " ")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
    }
    func append(_ text: String, now: Date = Date()) throws -> String? {
        let second = floor(now.timeIntervalSince1970)
        if second != rateSecond { rateSecond = second; rateCount = 0 }
        guard rateCount < policy.linesPerSecond else { return nil }
        rateCount += 1
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: now))] \(Self.clean(text))\n"
        let data = Data(line.utf8)
        guard data.count <= policy.logFileBytes else { return nil }
        if handle == nil || bytes + data.count > policy.logFileBytes {
            try handle?.close(); handle = nil
            current = directory.appendingPathComponent("session-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString).log")
            try PrivateFiles.write(Data(), to: current!)
            let fd = Darwin.open(current!.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw PrivateFiles.error("无法打开私有日志。") }
            do { _ = try PrivateFiles.checked(fd) } catch { close(fd); throw error }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); bytes = 0
        }
        try handle?.write(contentsOf: data); bytes += data.count
        if now.timeIntervalSince(lastPrune) >= 60 || bytes == data.count { try prune(now: now) }
        return line
    }
    func saveRecording(wave: Data, compressed: Data, metadata: Data, now: Date = Date()) throws -> URL {
        let base = "remote-\(Int(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        let url = directory.appendingPathComponent(base + ".wav")
        try PrivateFiles.write(wave, to: url, limit: 2_000_000)
        try PrivateFiles.write(compressed, to: directory.appendingPathComponent(base + ".adpcm"), limit: 500_000)
        try PrivateFiles.write(metadata, to: directory.appendingPathComponent(base + ".json"), limit: 1_048_576)
        try prune(now: now)
        return url
    }
    func maintenance(now: Date = Date()) throws {
        if now.timeIntervalSince(lastPrune) >= 3600 { try prune(now: now) }
    }
    func prune(now: Date) throws {
        struct Entry { let url: URL; let size: Int; let date: Date; let log: Bool }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var entries: [Entry] = []
        for url in urls {
            let name = url.lastPathComponent
            let isLog = name.hasPrefix("session-") && url.pathExtension == "log"
            let isRecording = name.hasPrefix("remote-") && ["wav", "adpcm", "json"].contains(url.pathExtension)
            guard isLog || isRecording else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1 else { continue }
            entries.append(Entry(url: url, size: Int(info.st_size), date: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)), log: isLog))
        }
        for isLog in [true, false] {
            var total = 0
            // Current log is retained first even when timestamps tie.
            let items = entries.filter { $0.log == isLog }.sorted {
                if $0.url == $1.url { return false }; if $0.url == current { return true }; if $1.url == current { return false }
                return $0.date > $1.date
            }
            for item in items {
                let budget = isLog ? policy.logTotalBytes : policy.recordingTotalBytes
                if item.url != current && (now.timeIntervalSince(item.date) > policy.maxAge || total + item.size > budget) {
                    try FileManager.default.removeItem(at: item.url)
                } else { total += item.size }
            }
        }
        lastPrune = now
    }
    func removeRecordings() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("remote-") && ["wav", "adpcm", "json"].contains(url.pathExtension) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}
