import Foundation

// Entirely synthetic packets, constructed here without captured Bluetooth data
// or upstream fixtures. Passing these checks does not establish real mic input.
func checkAppleVoiceHandleCompatibility() throws {
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    let selected = "11:22:33:44:55:66"
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ended = Data(repeating: 0, count: 99)

    func voice(_ sequence: UInt16) -> Data {
        var bytes = [UInt8](repeating: 0, count: 99)
        bytes[2] = UInt8(truncatingIfNeeded: sequence)
        bytes[3] = UInt8(truncatingIfNeeded: sequence >> 8)
        bytes[4] = 3
        bytes[5] = 0xB8; bytes[6] = 0xFF; bytes[7] = 0xFE
        return Data(bytes)
    }
    func line(_ att: UInt16, acl: UInt16 = 0x0407, sequence: UInt16 = 0,
              at offset: TimeInterval = 0, payload: Data? = nil,
              address: String? = nil, direction: String = "RECV", opcode: UInt8 = 0x1B) -> String {
        func littleEndian(_ value: UInt16) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
        }
        var raw = littleEndian(acl) + littleEndian(106) + littleEndian(102) + littleEndian(4)
        raw += [opcode] + littleEndian(att)
        raw += Array(payload ?? voice(sequence))
        return [formatter.string(from: epoch.addingTimeInterval(offset)), "ATT Receive",
                address ?? selected, String(format: "0x%04X", Int(acl)), direction,
                raw.map { String(format: "%02X", Int($0)) }.joined(separator: " "), ""]
            .joined(separator: "\t")
    }
    func noReport(_ value: AppleVoiceTransport.Event?, _ reason: String) {
        if case .report? = value { check(false, reason) }
        else { check(true, reason) }
    }

    for handle: UInt16 in [0x35, 0x36, 0x37, 0x01, 0x0100, 0x0137, 0xFFFF] {
        var transport = AppleVoiceTransport(address: selected)
        check(transport.receive(line(handle), now: epoch) == .report(voice(0), newStream: true),
              "valid voice learns a nonzero full-width ATT handle")
        check(transport.receive(line(handle, sequence: 1, at: 0.02), now: epoch.addingTimeInterval(0.02)) ==
              .report(voice(1), newStream: false), "same learned ACL and ATT retain codec stream")
        check(transport.diagnostics.dynamicHandleReports == ([0x35, 0x36].contains(handle) ? 0 : 2),
              "dynamic handle count includes valid frames outside historical handles")
        check(transport.diagnostics.voiceHandleChanges == 0, "initial discovery is not a handle change")
    }

    var invalid = AppleVoiceTransport(address: selected)
    noReport(invalid.receive(line(0), now: epoch), "zero ATT handle cannot produce audio")
    noReport(invalid.receive(line(0x37, opcode: 0x1D), now: epoch), "different ATT opcode is not learned")
    var unrelated = voice(0); unrelated[5] = 0xF8
    noReport(invalid.receive(line(0x37, payload: unrelated), now: epoch), "non-voice report is not emitted")
    var malformed = voice(0); malformed[4] = 95
    noReport(invalid.receive(line(0x37, payload: malformed), now: epoch), "out-of-bounds codec payload is not emitted")
    for size in [0, 98, 100] {
        noReport(invalid.receive(line(0x37, payload: Data(repeating: 0, count: size)), now: epoch),
                 "ATT handle compatibility does not broaden the 99-byte report contract")
    }
    check(invalid.diagnostics.dynamicHandleReports == 0, "rejected frames do not count as dynamic audio")
    check(invalid.receive(line(0x35, sequence: 10, at: 0.02), now: epoch.addingTimeInterval(0.02)) ==
          .report(voice(10), newStream: true), "invalid candidates cannot establish a prior voice stream")
    noReport(invalid.receive(line(0x1234, sequence: 11, at: 0.04, payload: malformed), now: epoch.addingTimeInterval(0.04)),
             "malformed report on another ATT handle never emits audio")
    check(invalid.receive(line(0x35, sequence: 11, at: 0.06), now: epoch.addingTimeInterval(0.06)) ==
          .report(voice(11), newStream: false), "malformed candidate cannot replace a learned voice handle")
    check(invalid.diagnostics.voiceHandleChanges == 0, "malformed candidate is not counted as a switch")

    var stream = AppleVoiceTransport(address: selected)
    check(stream.receive(line(0x37, payload: ended), now: epoch) == nil, "unbound zero sentinel is ignored")
    check(stream.receive(line(0x35, at: 0.02), now: epoch.addingTimeInterval(0.02)) ==
          .report(voice(0), newStream: true), "zero sentinel does not bind an ATT handle")
    check(stream.receive(line(0x37, at: 0.04, payload: ended), now: epoch.addingTimeInterval(0.04)) == nil,
          "zero sentinel from another ATT handle cannot end the active stream")
    check(stream.receive(line(0x35, acl: 0x0408, at: 0.06, payload: ended), now: epoch.addingTimeInterval(0.06)) == nil,
          "zero sentinel from another ACL cannot end the active stream")
    check(stream.receive(line(0x35, sequence: 1, at: 0.08), now: epoch.addingTimeInterval(0.08)) ==
          .report(voice(1), newStream: false), "unbound sentinels do not reset active codec state")
    check(stream.diagnostics.unboundEndReports == 3, "unbound end reports have a fixed aggregate counter")
    check(stream.receive(line(0x35, at: 0.10, payload: ended), now: epoch.addingTimeInterval(0.10)) ==
          .report(ended, newStream: false), "matching learned end marker closes the active stream")
    check(stream.receive(line(0x35, at: 0.12, payload: ended), now: epoch.addingTimeInterval(0.12)) == nil,
          "another sentinel after closure is unbound")
    check(stream.receive(line(0x35, sequence: 0, at: 0.14), now: epoch.addingTimeInterval(0.14)) ==
          .report(voice(0), newStream: true), "frame after a matching end begins a new decoder stream")
    check(stream.receive(line(0x37, sequence: 0, at: 0.16), now: epoch.addingTimeInterval(0.16)) ==
          .report(voice(0), newStream: true), "valid frame on another ATT handle resets the decoder")
    check(stream.receive(line(0x37, sequence: 1, at: 0.18), now: epoch.addingTimeInterval(0.18)) ==
          .report(voice(1), newStream: false), "subsequent dynamic ATT frames preserve their stream")
    check(stream.receive(line(0x37, acl: 0x0408, sequence: 0, at: 0.20), now: epoch.addingTimeInterval(0.20)) ==
          .report(voice(0), newStream: true), "new ACL with same ATT starts a fresh stream")
    check(stream.receive(line(0x35, sequence: 0, at: 0.22), now: epoch.addingTimeInterval(0.22)) ==
          .report(voice(0), newStream: true), "switching back is another fresh stream")
    check(stream.diagnostics.voiceHandleChanges == 3, "only active valid voice identity changes are counted")

    var isolated = AppleVoiceTransport(address: selected, sessionStartedAt: epoch)
    let lateNow = epoch.addingTimeInterval(2)
    check(isolated.receive(line(0x37, sequence: 7, at: 1), now: lateNow) ==
          .report(voice(7), newStream: true), "session gate admits delayed current-session dynamic handle")
    check(isolated.receive(line(0x1234, at: 1.01, address: "22:33:44:55:66:77"), now: lateNow) == nil,
          "another device cannot replace the selected device voice handle")
    check(isolated.receive(line(0x1234, at: 1.01, direction: "SEND"), now: lateNow) == nil,
          "outgoing traffic cannot replace the receive stream")
    check(isolated.receive(line(0x37, sequence: 8, at: 1.02), now: lateNow) ==
          .report(voice(8), newStream: false), "foreign device and direction preserve selected stream")
    check(isolated.receive(line(0x1234, at: -1), now: lateNow) == .reset,
          "dynamic handle cannot bypass pre-session time rejection")
    check(isolated.receive(line(0x1234, at: 3), now: lateNow) == .reset,
          "dynamic handle cannot bypass future time rejection")
    check(isolated.receive(line(0x37, sequence: 8, at: 1.02), now: lateNow) == nil,
          "stream reset cannot replay accepted same-identity audio")
    check(isolated.receive(line(0x37, sequence: 9, at: 1.04), now: lateNow) ==
          .report(voice(9), newStream: true), "fresh audio recovers after timing rejection")

    var sameTime = AppleVoiceTransport(address: selected, sessionStartedAt: epoch)
    check(sameTime.receive(line(0x35, sequence: 7, at: 1), now: lateNow) ==
          .report(voice(7), newStream: true), "first identity establishes session watermark")
    check(sameTime.receive(line(0x37, sequence: 7, at: 1), now: lateNow) ==
          .report(voice(7), newStream: true), "same timestamp and sequence on new ATT is fresh audio")
    check(sameTime.receive(line(0x37, acl: 0x0408, sequence: 7, at: 1), now: lateNow) ==
          .report(voice(7), newStream: true), "same timestamp and sequence on new ACL is fresh audio")
    check(sameTime.receive(line(0x35, sequence: 7, at: 1), now: lateNow) == nil,
          "switching identity back cannot replay already accepted audio")
    check(sameTime.receive(line(0x37, acl: 0x0408, sequence: 8, at: 1), now: lateNow) ==
          .report(voice(8), newStream: false), "rejected replay cannot steal the active identity")
    sameTime.reset()
    check(sameTime.receive(line(0x37, acl: 0x0408, sequence: 8, at: 1), now: lateNow) == nil,
          "full identity replay protection survives explicit reset")
    check(sameTime.receive(line(0x0137, sequence: 9, at: 0.99), now: lateNow) == .reset,
          "earlier audio remains rejected even when it uses an unseen ATT handle")
    check(sameTime.receive(line(0x37, acl: 0x0408, sequence: 9, at: 1.02), now: lateNow) ==
          .report(voice(9), newStream: true), "new frame resumes after preserved replay watermark")

    var endIdentity = AppleVoiceTransport(address: selected, sessionStartedAt: epoch)
    for handle: UInt16 in [0x35, 0x37] {
        check(endIdentity.receive(line(handle, sequence: 0, at: 1), now: lateNow) ==
              .report(voice(0), newStream: true), "new identity may begin within the same printed millisecond")
        check(endIdentity.receive(line(handle, at: 1, payload: ended), now: lateNow) ==
              .report(ended, newStream: false), "end deduplication is specific to the learned stream identity")
    }
    check(endIdentity.receive(line(0x35, sequence: 1, at: 1), now: lateNow) ==
          .report(voice(1), newStream: true), "distinct frame can restart a previously ended identity")
    check(endIdentity.receive(line(0x35, at: 1, payload: ended), now: lateNow) == nil,
          "old same-identity end cannot replay into a restarted stream")
    check(endIdentity.receive(line(0x35, sequence: 2, at: 1), now: lateNow) ==
          .report(voice(2), newStream: false), "rejected end replay preserves the active stream")

    // Frame and end identities share one 1024-entry budget per printed
    // timestamp. Using different handles keeps every synthetic key distinct.
    var boundedKeys = AppleVoiceTransport(address: selected, sessionStartedAt: epoch)
    for number in 1...512 {
        let handle = UInt16(number)
        check(boundedKeys.receive(line(handle, sequence: 0, at: 1), now: lateNow) ==
              .report(voice(0), newStream: true), "frame fits within the combined session-key budget")
        check(boundedKeys.receive(line(handle, at: 1, payload: ended), now: lateNow) ==
              .report(ended, newStream: false), "end identity shares the combined session-key budget")
    }
    check(boundedKeys.diagnostics.audioFrameReports == 512 && boundedKeys.diagnostics.endReports == 512,
          "512 frame identities and 512 end identities exactly fill the shared limit")
    check(boundedKeys.receive(line(513, sequence: 0, at: 1), now: lateNow) == nil,
          "a distinct 1025th identity is rejected instead of expanding session memory")
    check(boundedKeys.diagnostics.replayedSessionReports == 1,
          "session-key capacity refusal remains visible through a fixed counter")
    check(boundedKeys.receive(line(513, sequence: 0, at: 1.001), now: lateNow) ==
          .report(voice(0), newStream: true), "the next printed millisecond clears the key budget and recovers")
    check(boundedKeys.receive(line(514, sequence: 0, at: 1), now: lateNow) == .reset,
          "budget recovery cannot admit an older timestamp with an unseen handle")
    check(boundedKeys.receive(line(513, sequence: 1, at: 1.002), now: lateNow) ==
          .report(voice(1), newStream: true), "fresh audio resumes after rejecting older unseen identity")

    let encoded = try JSONEncoder().encode(stream.diagnostics)
    let numbers = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    check(numbers.values.allSatisfy { $0 is NSNumber }, "handle diagnostics remain numeric aggregates")
    check(numbers["dynamicHandleReports"] != nil && numbers["voiceHandleChanges"] != nil && numbers["unboundEndReports"] != nil,
          "all new failure distinctions are exposed as fixed counters")
    check(!String(decoding: encoded, as: UTF8.self).contains(selected), "diagnostics contain no bound device address")

    // Real libopus decoding of synthetic silence checks the transport/decoder
    // boundary only. It deliberately does not create a WAV or open a mic.
    var codecTransport = AppleVoiceTransport(address: selected)
    let decoder = try AppleVoiceDecoder()
    for (index, handle) in [UInt16(0x35), 0x37, 0x0137, 0xFFFF].enumerated() {
        let time = Double(index) * 0.02
        guard case let .report(payload, newStream)? = codecTransport.receive(line(handle, at: time), now: epoch.addingTimeInterval(time)) else {
            check(false, "compatible handle reaches decoder"); continue
        }
        check(newStream, "each new ATT resets sequence and codec memory")
        if newStream { try decoder.reset() }
        let pcm = try decoder.consume(reportID: 0xFA, payload: payload)
        check(pcm.count == 960, "dynamic ATT voice report decodes one 20ms frame at 48kHz")
    }
}
