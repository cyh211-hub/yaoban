// GPL-3.0. A bounded, selected-device .pklg adapter. No capture or filesystem IO.
import Foundation

struct AppleVoicePacketLog {
    typealias Event = AppleVoiceTransport.Event
    struct Diagnostics: Encodable {
        var records = 0
        var invalidRecords = 0
        var connectionEvents = 0
        var selectedConnections = 0
        var disconnects = 0
        var unboundACL = 0
        var otherACL = 0
        var selectedACL = 0
        var otherRecords = 0
        var invalidACL = 0
        var outOfOrder = 0
        var reports = 0
        var endReports = 0
        var unboundEnds = 0
        var duplicateReports = 0
        var partialBytesAtEOF = 0
    }
    private let addressBytes: [UInt8]
    private let startedAt: TimeInterval
    private var lastArrival: TimeInterval
    private var buffer = Data()
    private var assembler: AppleVoiceACLReassembler?
    private var highWater: UInt64?
    private var keysAtHighWater = Set<UInt64>()
    private var activeAttribute: UInt16?
    private var lastVoiceTime: UInt64?
    private(set) var stopped = false
    private(set) var diagnostics = Diagnostics()
    var bufferedBytes: Int { buffer.count + (assembler?.bufferedBytes ?? 0) }

    init?(address: String, startedAt: TimeInterval) {
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 }),
              startedAt.isFinite, startedAt >= 0 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        addressBytes = bytes.reversed()
        self.startedAt = startedAt; lastArrival = startedAt
    }

    // Caller must feed only a newly created capture owned by this bounded
    // session. Absolute PacketLogger times are NOT reliable on all macOS builds;
    // use them only for ordering/gaps. Session freshness is established by the
    // private producer file, start handshake, monotonic lifetime and binding.
    mutating func receive(_ chunk: Data, now: TimeInterval) -> [Event] {
        guard !stopped else { return [] }
        guard now.isFinite, now >= lastArrival, now - startedAt <= 23,
              chunk.count <= 65536, buffer.count + chunk.count <= 131088 else {
            return fail()
        }
        lastArrival = now; buffer.append(chunk)
        var events: [Event] = [], offset = 0
        while !stopped && buffer.count - offset >= 4 {
            func u32(_ i: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(buffer[offset + i + $1]) }
            }
            let length = Int(u32(0))
            guard (9...65548).contains(length) else { events += fail(); break }
            guard buffer.count - offset >= length + 4 else { break }
            let micros = u32(8)
            guard micros < 1_000_000 else { events += fail(); break }
            let stamp = UInt64(u32(4)) * 1_000_000 + UInt64(micros)
            let type = buffer[offset + 12]
            let payload = Array(buffer[(offset + 13)..<(offset + length + 4)])
            offset += length + 4
            diagnostics.records += 1
            if type == 1 { events += handleEvent(payload) }
            else if type == 3 { events += handleACL(payload, stamp: stamp) }
            else { diagnostics.otherRecords += 1 }
        }
        // Copy to normalize Data indices after a prefix has been consumed.
        if !stopped && offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
        return events
    }

    mutating func finish() {
        diagnostics.partialBytesAtEOF = buffer.count + (assembler?.bufferedBytes ?? 0)
        stopped = true; buffer.removeAll(); assembler = nil
    }

    private mutating func fail() -> [Event] {
        diagnostics.invalidRecords += 1
        stopped = true; buffer.removeAll(); assembler = nil
        return [.reset]
    }

    private mutating func handleEvent(_ bytes: [UInt8]) -> [Event] {
        guard bytes.count >= 2, Int(bytes[1]) == bytes.count - 2 else { return fail() }
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        if bytes[0] == 5, bytes.count == 6, bytes[2] == 0,
           assembler?.selectedHandle == u16(3) {
            diagnostics.disconnects += 1; stopped = true
            buffer.removeAll(); assembler = nil; return [.reset]
        }
        guard bytes[0] == 0x3E, bytes.count >= 4 else { return [] }
        // LE Connection Complete / LE Enhanced Connection Complete. Unknown
        // event layouts never establish a selected-device connection.
        guard (bytes[2] == 1 && bytes.count == 21) ||
              (bytes[2] == 0x0A && bytes.count == 33), bytes[3] == 0 else { return [] }
        diagnostics.connectionEvents += 1
        let handle = u16(4)
        guard handle <= 0x0EFF, bytes[6] <= 1, bytes[7] <= 3 else { return [] }
        let selected = Array(bytes[8..<14]) == addressBytes ||
            (bytes[2] == 0x0A && bytes[7] >= 2 && Array(bytes[20..<26]) == addressBytes)
        if selected {
            assembler = AppleVoiceACLReassembler(selectedHandle: handle)
            activeAttribute = nil; lastVoiceTime = nil
            diagnostics.selectedConnections += 1
            // Preserve ordering/dedup across a repeated connection snapshot.
            return [.reset]
        }
        if assembler?.selectedHandle == handle {
            // A handle reused by a different device cannot inherit this stream.
            stopped = true; assembler = nil; buffer.removeAll(); return [.reset]
        }
        return []
    }

    private mutating func handleACL(_ bytes: [UInt8], stamp: UInt64) -> [Event] {
        guard bytes.count >= 4 else { diagnostics.invalidACL += 1; return [] }
        guard let selected = assembler?.selectedHandle else { diagnostics.unboundACL += 1; return [] }
        let handle = (UInt16(bytes[0]) | UInt16(bytes[1]) << 8) & 0x0FFF
        guard handle == selected else { diagnostics.otherACL += 1; return [] }
        diagnostics.selectedACL += 1
        guard highWater.map({ stamp >= $0 }) ?? true else {
            diagnostics.outOfOrder += 1; assembler?.reset()
            activeAttribute = nil; lastVoiceTime = nil; return [.reset]
        }
        if highWater.map({ stamp > $0 }) ?? true {
            highWater = stamp; keysAtHighWater.removeAll(keepingCapacity: true)
        }
        guard let value = assembler?.receive(Data(bytes), now: Double(stamp) / 1_000_000),
              let report = AppleVoiceReport.parse(reportID: 0xFA, payload: value.payload) else { return [] }
        let gap = lastVoiceTime.map({ stamp - $0 > 150_000 }) ?? true
        let changed = activeAttribute != value.attribute
        let key: UInt64
        switch report {
        case let .frame(sequence, _): key = UInt64(value.attribute) << 16 | UInt64(sequence)
        case .ended:
            guard !changed, !gap else { diagnostics.unboundEnds += 1; return [] }
            key = 1 << 32 | UInt64(value.attribute)
        }
        guard keysAtHighWater.count < 1024, keysAtHighWater.insert(key).inserted else {
            diagnostics.duplicateReports += 1; return []
        }
        switch report {
        case .frame:
            activeAttribute = value.attribute; lastVoiceTime = stamp
            diagnostics.reports += 1
            return [.report(value.payload, newStream: changed || gap)]
        case .ended:
            activeAttribute = nil; lastVoiceTime = nil; diagnostics.endReports += 1
            return [.report(value.payload, newStream: false)]
        }
    }
}
