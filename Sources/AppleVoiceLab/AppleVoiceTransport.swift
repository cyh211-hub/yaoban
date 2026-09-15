// GPL-3.0. PacketLogger 26 `convert -s -f itpahdr` adapter. No capture or disk access.
import Foundation

struct AppleVoiceTransport {
    enum Event: Equatable { case reset; case report(Data, newStream: Bool) }
    // Fixed aggregate counts only. Never retain a line, address, packet type from
    // input, raw bytes, or packet timestamps for diagnostic output. Frame counts
    // mean this experimental report shape matched, not that Opus decoded it.
    struct Diagnostics: Encodable {
        var lines = 0
        var oversizedLines = 0
        var malformedFormatLines = 0
        var nonReceiveLines = 0
        var otherDeviceLines = 0
        var selectedDeviceLines = 0
        var invalidTimestamps = 0
        var staleOrFutureTimestamps = 0
        var outOfOrderTimestamps = 0
        var malformedHexLines = 0
        var hciEventLines = 0
        var disconnectEvents = 0
        var unrelatedPacketTypes = 0
        var attReceiveLines = 0
        var unrecognizedATTShape = 0
        var invalidTransportHeaders = 0
        var unrelatedATTValues = 0
        var reportEnvelopes = 0
        var audioFrameReports = 0
        var endReports = 0
        var malformedAudioReports = 0
        var replayedSessionReports = 0
        var dynamicHandleReports = 0
        var voiceHandleChanges = 0
        var unboundEndReports = 0
    }
    let address: String
    private(set) var diagnostics = Diagnostics()
    private(set) var timingDiagnostics = AppleVoiceTimingDiagnostics()
    private(set) var wireDiagnostics = AppleVoiceWireDiagnostics()
    private let sessionStartedAt: Date?
    // Stream reset cannot make already accepted session audio fresh again.
    private var sessionHighWaterTime: Date?
    private var sessionSequencesAtHighWater = Set<UInt64>()
    private var sessionEndsAtHighWater = Set<UInt32>()
    private var connection: UInt16?
    private var voiceAttribute: UInt16?
    private var lastTime: Date?
    private var needsReset = true
    private let dates: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()

    init(address: String, sessionStartedAt: Date? = nil) {
        self.address = address.uppercased()
        self.sessionStartedAt = sessionStartedAt
    }
    mutating func reset() {
        connection = nil; voiceAttribute = nil
        lastTime = nil; needsReset = true
    }

    mutating func receive(_ line: String, now: Date) -> Event? {
        diagnostics.lines += 1
        guard line.utf8.count <= 8192 else {
            diagnostics.oversizedLines += 1; reset(); return .reset
        }
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard columns.count == 7, columns[6].isEmpty else {
            diagnostics.malformedFormatLines += 1; return nil
        }
        guard columns[4] == "RECV" else { diagnostics.nonReceiveLines += 1; return nil }
        // Never infer a device from its name, nearest signal, or a cached connection
        // number. Every audio fragment must carry the selected device's address.
        guard columns[2].uppercased() == address else { diagnostics.otherDeviceLines += 1; return nil }
        diagnostics.selectedDeviceLines += 1
        wireDiagnostics.observe(hex: columns[5], displayedHandle: columns[3], packetType: columns[1])
        guard let timestamp = dates.date(from: columns[0]) else {
            diagnostics.invalidTimestamps += 1; reset(); return .reset
        }
        let lag = now.timeIntervalSince(timestamp)
        timingDiagnostics.observe(lagSeconds: lag)
        // Classify only the selected device's known packet category even when
        // timing rejects it; zero audio inspection must not look like no ATT.
        if columns[1] == "ATT Receive" { diagnostics.attReceiveLines += 1 }
        else if columns[1] == "HCI Event" { diagnostics.hciEventLines += 1 }
        else { diagnostics.unrelatedPacketTypes += 1 }
        let eligible: Bool
        if let sessionStartedAt {
            // This path produces a bounded WAV, not live keyboard/voice input.
            // Queueing within this one short session must not lose the entire
            // recording. Reject pre-session history, future data and expired
            // sessions; never calibrate an arbitrary clock offset from a packet.
            eligible = (0...AppleVoiceSessionClock.duration).contains(now.timeIntervalSince(sessionStartedAt)) &&
                timestamp.timeIntervalSince(sessionStartedAt) >= -0.1 && lag >= -0.1
        } else {
            eligible = (-0.1...0.25).contains(lag)
        }
        guard eligible else {
            diagnostics.staleOrFutureTimestamps += 1; reset(); return .reset
        }
        guard (lastTime.map({ timestamp >= $0 }) ?? true) &&
              (sessionHighWaterTime.map({ timestamp >= $0 }) ?? true) else {
            diagnostics.outOfOrderTimestamps += 1; reset(); return .reset
        }
        let words = columns[5].split(separator: " ")
        guard !words.isEmpty, words.count <= 2048,
              words.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else {
            diagnostics.malformedHexLines += 1; reset(); return .reset
        }
        let raw = words.compactMap { UInt8($0, radix: 16) }
        if columns[1] == "HCI Event" {
            if raw.count == 6, raw[0] == 5, raw[1] == 4 {
                diagnostics.disconnectEvents += 1
                reset(); return .reset // matched-device disconnect
            }
            return nil
        }
        guard columns[1] == "ATT Receive" else { return nil }
        guard raw.count == 110, columns[3].hasPrefix("0x"),
              let displayed = UInt16(columns[3].dropFirst(2), radix: 16) else {
            diagnostics.unrecognizedATTShape += 1; return nil
        }
        func u16(_ offset: Int) -> UInt16 { UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8 }
        let header = u16(0), handle = header & 0x0FFF, boundary = (header >> 12) & 3
        // The offline PacketLogger fixture reassembles ATT and retains the FIRST
        // fragment's ACL length (e.g. 40) alongside the complete L2CAP PDU. This
        // adapter accepts that complete shape; it does not yet reassemble partial
        // live ACL lines. Offline conversion alone cannot prove live reassembly.
        guard handle <= 0x0EFF, handle == displayed, header & 0xC000 == 0,
              [0,2].contains(boundary), (4...106).contains(u16(2)),
              u16(4) == 102, u16(6) == 4 else {
            diagnostics.invalidTransportHeaders += 1; reset(); return .reset
        }
        let value = Array(raw.dropFirst(8))
        let attribute = UInt16(value[1]) | UInt16(value[2]) << 8
        // Attribute handles are allocated by the remote's GATT layout. They are
        // stream identity, not an audio signature. Learn one only after the
        // selected device, complete transport and A2854 voice framing validate.
        guard value[0] == 0x1B, attribute != 0 else {
            diagnostics.unrelatedATTValues += 1; return nil
        }
        let payload = Data(value.dropFirst(3))
        diagnostics.reportEnvelopes += 1
        guard let parsed = AppleVoiceReport.parse(reportID: 0xFA, payload: payload) else {
            diagnostics.malformedAudioReports += 1; return nil
        }
        let streamChanged = connection != handle || voiceAttribute != attribute
        let gapExpired = lastTime.map({ timestamp.timeIntervalSince($0) > 0.15 }) ?? true
        if parsed == .ended && (streamChanged || gapExpired) {
            // Zero-filled non-voice characteristics must neither establish a
            // voice stream nor terminate a different characteristic's speech.
            diagnostics.unboundEndReports += 1; return nil
        }
        if sessionStartedAt != nil {
            if sessionHighWaterTime.map({ timestamp > $0 }) ?? true {
                sessionHighWaterTime = timestamp
                sessionSequencesAtHighWater.removeAll(keepingCapacity: true)
                sessionEndsAtHighWater.removeAll(keepingCapacity: true)
            }
            let streamKey = UInt32(handle) << 16 | UInt32(attribute)
            let hasCapacity = sessionSequencesAtHighWater.count + sessionEndsAtHighWater.count < 1024
            switch parsed {
            case let .frame(sequence, _):
                // Different streams may start with the same sequence within one
                // printed millisecond. Include both handles, and retain these
                // bounded keys across stream switches and resets.
                let frameKey = UInt64(streamKey) << 16 | UInt64(sequence)
                guard hasCapacity, !sessionSequencesAtHighWater.contains(frameKey) else {
                    diagnostics.replayedSessionReports += 1; return nil
                }
                sessionSequencesAtHighWater.insert(frameKey)
            case .ended:
                guard hasCapacity, !sessionEndsAtHighWater.contains(streamKey) else {
                    diagnostics.replayedSessionReports += 1; return nil
                }
                sessionEndsAtHighWater.insert(streamKey)
            }
        }
        switch parsed {
        case .frame:
            if streamChanged || gapExpired {
                if connection != nil && streamChanged { diagnostics.voiceHandleChanges += 1 }
                reset(); connection = handle; voiceAttribute = attribute
            }
            lastTime = timestamp
            diagnostics.audioFrameReports += 1
            if ![0x35, 0x36].contains(attribute) { diagnostics.dynamicHandleReports += 1 }
            let fresh = needsReset; needsReset = false
            return .report(payload, newStream: fresh)
        case .ended:
            diagnostics.endReports += 1
            reset()
            return .report(payload, newStream: false)
        }
    }
}
