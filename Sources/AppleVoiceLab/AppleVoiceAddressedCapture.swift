// GPL-3.0. Address-annotated live capture from a fresh private regular file.
// Never use with historical exports: freshness belongs to the bounded producer,
// not PacketLogger's wall clock (which can be offset on some macOS builds).
import Foundation

struct AppleVoiceAddressedCapture {
    typealias Event = AppleVoiceTransport.Event
    struct Diagnostics: Encodable {
        var lines = 0
        var malformedLines = 0
        var otherDeviceLines = 0
        var nonReceiveLines = 0
        var selectedAddressRecords = 0
        var invalidHex = 0
        var missingACLHeader = 0
        var headerMismatch = 0
        var lengthMismatch = 0
        var selectedPackets = 0
        var invalidPackets = 0
        var completePDUs = 0
        var reports = 0
        var endReports = 0
        var unboundEnds = 0
        var duplicateReports = 0
        var outOfOrder = 0
        var disconnects = 0
    }
    private let address: String
    private let startedAt: Double
    private let duration: Double
    private var lastArrival: Double
    private var assembler: AppleVoiceACLReassembler?
    private var highWater: Double?
    private var keys = Set<UInt64>()
    private var activeAttribute: UInt16?
    private var lastVoice: Double?
    private let dates: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    private(set) var diagnostics = Diagnostics()
    private(set) var wireDiagnostics = AppleVoiceWireDiagnostics()
    private(set) var stopped = false

    init?(address: String, startedAt: Double, duration: Double = 23) {
        guard duration.isFinite, duration > 0, duration <= 65, AppleVoicePacketLog(address: address, startedAt: startedAt) != nil else { return nil }
        self.address = address.uppercased(); self.duration = duration
        self.startedAt = startedAt; self.lastArrival = startedAt
    }

    private mutating func reset() -> Event {
        assembler?.reset(); activeAttribute = nil; lastVoice = nil
        return .reset
    }

    mutating func receive(_ line: String, now: Double) -> Event? {
        guard !stopped else { return nil }
        guard now.isFinite, now >= lastArrival, now - startedAt <= duration else {
            stopped = true; return reset()
        }
        lastArrival = now; diagnostics.lines += 1
        guard line.utf8.count <= 8192 else {
            diagnostics.malformedLines += 1; stopped = true; return reset()
        }
        let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard c.count == 7, c[6].isEmpty else { diagnostics.malformedLines += 1; return nil }
        guard c[4] == "RECV" else { diagnostics.nonReceiveLines += 1; return nil }
        // Identity comes from Apple's live address annotation on EVERY packet,
        // including continuations; a valid Opus payload cannot establish identity.
        guard c[2].uppercased() == address else { diagnostics.otherDeviceLines += 1; return nil }
        guard let date = dates.date(from: c[0]) else { diagnostics.malformedLines += 1; return reset() }
        let stamp = date.timeIntervalSince1970
        guard highWater.map({ stamp >= $0 }) ?? true else {
            diagnostics.outOfOrder += 1; return reset()
        }
        if highWater.map({ stamp > $0 }) ?? true { highWater = stamp; keys.removeAll(keepingCapacity: true) }
        // Readiness means Apple's live stream names the bound source, not that
        // a control/status packet already has an audio-compatible ACL envelope.
        // Audio remains subject to every transport/report check below.
        diagnostics.selectedAddressRecords += 1
        wireDiagnostics.observe(hex: c[5], displayedHandle: c[3], packetType: c[1])
        let words = c[5].split(separator: " ")
        guard !words.isEmpty, words.count <= 2048,
              words.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else {
            diagnostics.invalidPackets += 1; diagnostics.invalidHex += 1; return reset()
        }
        var raw = words.compactMap { UInt8($0, radix: 16) }
        if c[1] == "HCI Event" {
            if raw.count == 6, raw[0] == 5, raw[1] == 4, raw[2] == 0 {
                stopped = true; diagnostics.disconnects += 1; return reset()
            }
            return nil
        }
        guard raw.count >= 4, c[3].hasPrefix("0x"),
              let displayed = UInt16(c[3].dropFirst(2), radix: 16) else {
            diagnostics.invalidPackets += 1; diagnostics.missingACLHeader += 1; return reset()
        }
        func u16(_ i: Int) -> UInt16 { UInt16(raw[i]) | UInt16(raw[i + 1]) << 8 }
        let header = u16(0), handle = header & 0xFFF, boundary = (header >> 12) & 3
        guard handle <= 0xEFF, handle == displayed, header & 0xC000 == 0, boundary <= 2 else {
            diagnostics.invalidPackets += 1; diagnostics.headerMismatch += 1; return reset()
        }
        // Apple's text decoder can expose the COMPLETE PDU with the first ACL
        // fragment's original length. Normalize only this exact voice envelope;
        // otherwise require an exact raw ACL length and reassemble ourselves.
        if raw.count == 110, [0, 2].contains(boundary), (4...106).contains(u16(2)),
           u16(4) == 102, u16(6) == 4, raw[8] == 0x1B,
           AppleVoiceReport.parse(reportID: 0xFA, payload: Data(raw[11...])) != nil {
            raw[2] = 106; raw[3] = 0
        }
        guard Int(u16(2)) == raw.count - 4 else {
            diagnostics.invalidPackets += 1; diagnostics.lengthMismatch += 1; return reset()
        }
        diagnostics.selectedPackets += 1
        let changedConnection = assembler?.selectedHandle != handle
        if changedConnection {
            assembler = AppleVoiceACLReassembler(selectedHandle: handle)
            activeAttribute = nil; lastVoice = nil
        }
        guard let value = assembler?.receive(Data(raw), now: stamp),
              let report = AppleVoiceReport.parse(reportID: 0xFA, payload: value.payload) else { return nil }
        diagnostics.completePDUs += 1
        let gap = lastVoice.map({ stamp - $0 > 0.15 }) ?? true
        let changed = activeAttribute != value.attribute
        let stream = UInt64(handle) << 16 | UInt64(value.attribute)
        let key: UInt64
        switch report {
        case let .frame(sequence, _): key = stream << 16 | UInt64(sequence)
        case .ended:
            guard !changed, !gap else { diagnostics.unboundEnds += 1; return nil }
            key = 1 << 63 | stream
        }
        guard keys.count < 1024, keys.insert(key).inserted else {
            diagnostics.duplicateReports += 1; return nil
        }
        switch report {
        case .frame:
            activeAttribute = value.attribute; lastVoice = stamp; diagnostics.reports += 1
            return .report(value.payload, newStream: changed || gap)
        case .ended:
            activeAttribute = nil; lastVoice = nil; diagnostics.endReports += 1
            return .report(value.payload, newStream: false)
        }
    }
}
