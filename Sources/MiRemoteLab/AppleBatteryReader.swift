import Foundation
import Darwin

// Read system metadata only. Never connects, subscribes to GATT, or guesses by model/name.
enum AppleBatteryMetadata {
    static func address(_ text:String) -> String? {
        let parts = text.replacingOccurrences(of:"-",with:":").split(separator:":",omittingEmptySubsequences:false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { "0123456789abcdefABCDEF".contains($0) } }) else { return nil }
        return parts.joined(separator:":").uppercased()
    }
    static func percent(_ data:Data, for target:String) -> Int? {
        guard data.count <= 1_048_576, let target = address(target),
              let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let sections = root["SPBluetoothDataType"] as? [[String:Any]] else { return nil }
        var matches = [Int?]()
        for section in sections {
            guard let groups = section["device_connected"] as? [[String:Any]] else { continue }
            for group in groups {
                for raw in group.values {
                    guard let device = raw as? [String:Any], let value = device["device_address"] as? String,
                          address(value) == target else { continue }
                    let rawLevel = device["device_batteryLevelMain"] as? String ?? ""
                    let text = rawLevel.trimmingCharacters(in:.whitespacesAndNewlines)
                    let digits = text.hasSuffix("%") ? String(text.dropLast()) : text
                    let level = !digits.isEmpty && digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(digits) : nil
                    matches.append(level.flatMap { (0...100).contains($0) ? $0 : nil })
                }
            }
        }
        // Duplicated/conflicting records are not live battery evidence.
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

final class AppleBatteryReader {
    private var task:Process?
    private var source:DispatchSourceRead?
    private var ticket = UUID()
    private var bytes = Data()
    private var nextRead:TimeInterval = 0
    private var target:String?
    func refresh(address:String, now:TimeInterval, receive:@escaping (Int)->Void) {
        guard let normalized = AppleBatteryMetadata.address(address) else { return }
        if target != normalized { stop(); target = normalized }
        guard task == nil, now >= nextRead else { return }
        nextRead = now + 60
        let process = Process(), pipe = Pipe(), current = UUID()
        ticket = current; bytes.removeAll(); task = process
        process.executableURL = URL(fileURLWithPath:"/usr/sbin/system_profiler")
        process.arguments = ["-json","SPBluetoothDataType"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let handle = pipe.fileHandleForReading, fd = handle.fileDescriptor
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor:fd,queue:.main)
        source = reader
        reader.setCancelHandler { try? handle.close() }
        reader.setEventHandler { [weak self] in
            guard let self, self.ticket == current else { return }
            var buffer = [UInt8](repeating:0,count:8192)
            let count = read(fd,&buffer,buffer.count)
            if count > 0 {
                guard self.bytes.count + count <= 1_048_576 else { self.stop(resetInterval:false); return }
                self.bytes.append(contentsOf:buffer.prefix(count))
            } else if count == 0 {
                let result = AppleBatteryMetadata.percent(self.bytes,for:normalized)
                self.source?.cancel(); self.source = nil; self.bytes.removeAll()
                if let result { receive(result) }
            } else if errno != EAGAIN && errno != EINTR { self.stop(resetInterval:false) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { guard let self, self.ticket == current else { return }; self.task = nil }
        }
        reader.resume()
        do { try process.run(); try? pipe.fileHandleForWriting.close() }
        catch { stop(resetInterval:false) }
        DispatchQueue.main.asyncAfter(deadline:.now()+8) { [weak self] in
            guard let self, self.ticket == current else { return }
            self.stop(resetInterval:false)
        }
    }
    func stop(resetInterval:Bool = true) {
        ticket = UUID(); source?.cancel(); source = nil
        if let task, task.isRunning {
            task.terminate()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                if task.isRunning { _ = kill(task.processIdentifier,SIGKILL) }
            }
        }
        task = nil; bytes.removeAll()
        if resetInterval { nextRead = 0; target = nil }
    }
}
