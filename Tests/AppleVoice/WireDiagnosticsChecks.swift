import Foundation

// Independent synthetic packet shapes only. These diagnostics do not assert
// that a candidate is current audio, call a decoder, or open a capture source.
func checkAppleVoiceWireDiagnostics() throws {
    let keys: Set<String> = ["inspectedSelectedPackets", "validHexPackets", "completeVoiceCandidates",
        "fragmentedVoiceCandidates", "aclContinuationCandidates", "voiceCandidatesOutsideATTLabel"]
    let address = "11:22:33:44:55:66"
    let unknownLabel = "private-synthetic-label-do-not-store"
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    func voice(_ sequence: UInt16 = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 99)
        bytes[2] = UInt8(truncatingIfNeeded: sequence)
        bytes[3] = UInt8(truncatingIfNeeded: sequence >> 8)
        bytes[4] = 3; bytes[5] = 0xB8; bytes[6] = 0xFF; bytes[7] = 0xFE
        return Data(bytes)
    }
    func packet(_ sequence: UInt16 = 0) -> [UInt8] {
        [0x07, 0x04, 106, 0, 102, 0, 4, 0, 0x1B, 0x37, 0x01] + Array(voice(sequence))
    }
    func hex(_ raw: [UInt8]) -> String {
        raw.map { String(format: "%02X", Int($0)) }.joined(separator: " ")
    }
    func inspect(_ raw: [UInt8], label: String = "ATT Receive", displayed: String = "0x0407") -> AppleVoiceWireDiagnostics {
        var value = AppleVoiceWireDiagnostics()
        value.observe(hex: hex(raw), displayedHandle: displayed, packetType: label)
        return value
    }
    func line(_ raw: [UInt8], label: String = "ATT Receive", selected: String? = nil,
              direction: String = "RECV", at offset: TimeInterval = 0, timestamp: String? = nil) -> String {
        [timestamp ?? formatter.string(from: epoch.addingTimeInterval(offset)), label,
         selected ?? address, "0x0407", direction, hex(raw), ""].joined(separator: "\t")
    }
    func hasNoVoice(_ value: AppleVoiceWireDiagnostics) -> Bool {
        value.completeVoiceCandidates == 0 && value.fragmentedVoiceCandidates == 0 &&
            value.voiceCandidatesOutsideATTLabel == 0
    }
    func encoded(_ value: AppleVoiceWireDiagnostics) throws -> [String: Int] {
        let data = try JSONEncoder().encode(value)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            check(false, "wire diagnostics must encode integer counters only"); return [:]
        }
        check(Set(result.keys) == keys, "wire diagnostics have exactly six fixed keys")
        check(result.values.allSatisfy { $0 >= 0 }, "wire diagnostics remain nonnegative")
        let text = String(decoding: data, as: UTF8.self)
        check(!text.contains(address) && !text.contains(unknownLabel) && !text.contains(hex(packet())),
              "wire diagnostics never retain device, raw label, or payload")
        return result
    }

    check(try encoded(AppleVoiceWireDiagnostics()).values.allSatisfy { $0 == 0 }, "empty wire counters start at zero")
    let complete = inspect(packet())
    check(complete.inspectedSelectedPackets == 1 && complete.validHexPackets == 1 && complete.completeVoiceCandidates == 1,
          "complete 110/102/99-byte valid voice shape is counted")
    check(complete.fragmentedVoiceCandidates == 0 && complete.aclContinuationCandidates == 0 && complete.voiceCandidatesOutsideATTLabel == 0,
          "complete ATT voice candidate is not mislabeled as a fragment or unknown category")
    let unknown = inspect(packet(), label: unknownLabel)
    check(unknown.completeVoiceCandidates == 1 && unknown.voiceCandidatesOutsideATTLabel == 1,
          "complete candidate under an unknown packet label remains visible")
    _ = try encoded(unknown)
    var offlineReassembled = packet(); offlineReassembled[2] = 40
    check(inspect(offlineReassembled).completeVoiceCandidates == 1,
          "complete shape permits preserved first-fragment ACL length")

    for size in 0..<110 {
        var raw = Array(packet().prefix(size))
        if size >= 4 { raw[2] = UInt8(size - 4); raw[3] = 0 }
        let value = inspect(raw, label: unknownLabel)
        check(value.completeVoiceCandidates == 0 && value.aclContinuationCandidates == 0,
              "a first fragment never counts as a complete report or continuation")
        check(value.fragmentedVoiceCandidates == (size >= 17 ? 1 : 0) &&
              value.voiceCandidatesOutsideATTLabel == (size >= 17 ? 1 : 0),
              "first-fragment candidate requires all header, declared-size and TOC bytes")
    }
    var fragment = Array(packet().prefix(40)); fragment[2] = 36
    var badFragmentLength = fragment; badFragmentLength[2] = 35
    check(hasNoVoice(inspect(badFragmentLength)), "fragment must match its declared ACL data length")
    for length: UInt8 in [0, 1, 95, 255] {
        var bad = fragment; bad[15] = length
        check(hasNoVoice(inspect(bad)), "fragment requires the bounded multi-byte codec packet shape")
    }

    for size in [5, 17, 40, 110] {
        var continuation = [UInt8](repeating: 0, count: size)
        continuation[0] = 0x07; continuation[1] = 0x14; continuation[2] = UInt8(size - 4)
        let value = inspect(continuation, label: unknownLabel)
        check(value.aclContinuationCandidates == 1 && hasNoVoice(value),
              "PB1 with matching ACL length is only a continuation-shape candidate")
        continuation[2] &+= 1
        check(inspect(continuation).aclContinuationCandidates == 0,
              "continuation size mismatch cannot count as a candidate")
    }
    for size in [0, 1, 4, 111] {
        var continuation = [UInt8](repeating: 0, count: size)
        if size >= 4 {
            continuation[0] = 0x07; continuation[1] = 0x14; continuation[2] = UInt8(size - 4)
        }
        check(inspect(continuation).aclContinuationCandidates == 0,
              "empty, truncated and oversized continuation envelopes are excluded")
    }

    for rawHex in ["", "GG", "0", "000", "ＦＦ", "00\n00", String(repeating: "00 ", count: 2049), String(repeating: "x", count: 8193)] {
        var value = AppleVoiceWireDiagnostics()
        value.observe(hex: rawHex, displayedHandle: "0x0407", packetType: unknownLabel)
        check(value.inspectedSelectedPackets == 1 && value.validHexPackets == 0 && hasNoVoice(value),
              "invalid or excessive hex cannot enter shape inspection")
    }
    for displayed in ["0407", "0xFFFF", "0x0408", "0xnot-a-handle"] {
        check(hasNoVoice(inspect(packet(), displayed: displayed)), "invalid or mismatched displayed connection is rejected")
    }
    for (index, replacement): (Int, UInt8) in [(1, 0xC4), (1, 0x34), (2, 0), (2, 107),
                                               (4, 101), (6, 5), (8, 0x1D), (15, 0), (15, 95), (16, 0xF8)] {
        var bad = packet(); bad[index] = replacement
        check(hasNoVoice(inspect(bad)), "bad ACL, L2CAP, ATT or voice header is not a voice candidate")
    }
    var invalidConnection = packet(); invalidConnection[0] = 0; invalidConnection[1] = 0x0F
    check(hasNoVoice(inspect(invalidConnection, displayed: "0x0F00")), "reserved connection number is excluded")
    var zeroAttribute = packet(); zeroAttribute[9] = 0; zeroAttribute[10] = 0
    check(hasNoVoice(inspect(zeroAttribute)), "zero ATT attribute is not a voice candidate")
    let endPacket = Array(packet().prefix(11)) + Array(repeating: UInt8(0), count: 99)
    check(hasNoVoice(inspect(endPacket)), "all-zero release marker is not evidence of a voice frame")
    check(hasNoVoice(inspect(packet() + [0])), "oversized complete envelope is not a voice candidate")

    var isolated = AppleVoiceTransport(address: address, sessionStartedAt: epoch)
    check(isolated.receive(line(packet(), label: unknownLabel, selected: "22:33:44:55:66:77", timestamp: "invalid-private-time"), now: epoch) == nil,
          "foreign device is excluded before observing its packet shape")
    check(isolated.receive(line(packet(), label: unknownLabel, direction: "SEND", timestamp: "invalid-private-time"), now: epoch) == nil,
          "outgoing traffic is excluded before shape inspection")
    check(isolated.wireDiagnostics.inspectedSelectedPackets == 0, "only selected-device RECV lines reach wire diagnostics")
    check(isolated.receive(line(packet(), label: unknownLabel, timestamp: "invalid-private-time"), now: epoch) == .reset,
          "invalid timestamp still refuses actual audio")
    check(isolated.wireDiagnostics.completeVoiceCandidates == 1 && isolated.wireDiagnostics.voiceCandidatesOutsideATTLabel == 1 &&
          isolated.diagnostics.audioFrameReports == 0, "shape remains observable despite timestamp rejection without admitting a report")
    check(isolated.receive(line(packet(), label: unknownLabel, at: 28_800), now: epoch) == .reset,
          "an eight-hour future timestamp never becomes accepted audio")
    check(isolated.wireDiagnostics.completeVoiceCandidates == 2 && isolated.wireDiagnostics.voiceCandidatesOutsideATTLabel == 2 &&
          isolated.diagnostics.audioFrameReports == 0, "future packet shape is diagnosed without bypassing the time gate")
    _ = try encoded(isolated.wireDiagnostics)

    var unchanged = AppleVoiceTransport(address: address)
    check(unchanged.receive(line(packet(), label: unknownLabel), now: epoch) == nil,
          "candidate under unknown label remains rejected by actual transport")
    check(unchanged.receive(line(fragment), now: epoch) == nil,
          "observed first-fragment candidate is not decoded or emitted as a report")
    check(unchanged.diagnostics.audioFrameReports == 0 && unchanged.wireDiagnostics.completeVoiceCandidates == 1 &&
          unchanged.wireDiagnostics.fragmentedVoiceCandidates == 1, "candidate counts stay distinct from accepted audio frames")
    check(unchanged.receive(line(packet()), now: epoch) == .report(voice(), newStream: true),
          "ordinary valid transport acceptance still works")
    check(unchanged.receive(line(packet(), label: unknownLabel, at: 0.02), now: epoch.addingTimeInterval(0.02)) == nil,
          "unknown-label observer cannot modify an active stream")
    check(unchanged.receive(line(packet(1), at: 0.04), now: epoch.addingTimeInterval(0.04)) == .report(voice(1), newStream: false),
          "shape inspection does not reset or rebind actual decoder stream state")
}
