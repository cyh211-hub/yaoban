import Foundation

func checkAppleVoicePacketLog() throws {
    let address = "11:22:33:44:55:66"
    func record(_ type: UInt8, _ payload: [UInt8], tick: UInt32 = 0, seconds: UInt32 = 1_800_000_000) -> Data {
        var d = Data()
        for value in [UInt32(payload.count + 9), seconds, tick] {
            var big = value.bigEndian; withUnsafeBytes(of: &big) { d.append(contentsOf: $0) }
        }
        d.append(type); d.append(contentsOf: payload); return d
    }
    func connected(_ handle: UInt16 = 0x51, foreign: Bool = false, enhanced: Bool = false) -> Data {
        var body: [UInt8] = [0x3E, enhanced ? 31 : 19, enhanced ? 0x0A : 1, 0,
                             UInt8(truncatingIfNeeded: handle), UInt8(handle >> 8), 0, 0,
                             foreign ? 0x77 : 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]
        body += Array(repeating: 0, count: enhanced ? 19 : 7)
        return record(1, body)
    }
    func acl(_ body: [UInt8], boundary: UInt16 = 2, handle: UInt16 = 0x51, tick: UInt32 = 0) -> Data {
        let h = handle | boundary << 12
        return record(3, [UInt8(truncatingIfNeeded: h), UInt8(h >> 8), UInt8(body.count), 0] + body, tick: tick)
    }
    func pdu(_ data: Data, attr: UInt16 = 0x35) -> [UInt8] {
        [102, 0, 4, 0, 0x1B, UInt8(truncatingIfNeeded: attr), UInt8(attr >> 8)] + data
    }
    let payload = report(12), body = pdu(payload)
    let first = acl(Array(body.prefix(40)))
    let last = acl(Array(body.dropFirst(40)), boundary: 1, tick: 1000)
    let all = connected() + first + last
    for width in [1, 2, 3, 4, 12, 13, 31, 40, 57, 64, 128, 4096] {
        var parser = AppleVoicePacketLog(address: address, startedAt: 5)!
        var events = [AppleVoiceTransport.Event]()
        var start = 0
        while start < all.count {
            let end = min(start + width, all.count)
            events += parser.receive(Data(all[start..<end]), now: 5 + Double(start) / 10000)
            start = end
        }
        check(events == [.reset, .report(payload, newStream: true)], "binary chunk boundaries preserve complete selected voice")
        check(parser.diagnostics.reports == 1 && parser.bufferedBytes == 0, "one binary PDU emits exactly once")
    }
    var unbound = AppleVoicePacketLog(address: address, startedAt: 0)!
    check(unbound.receive(first + last, now: 0).isEmpty, "audio cannot learn connection identity")
    check(unbound.diagnostics.unboundACL == 2, "unbound data is explicitly diagnosed")
    var foreign = AppleVoicePacketLog(address: address, startedAt: 0)!
    check(foreign.receive(connected(foreign: true) + first + last, now: 0).isEmpty,
          "valid voice on another address cannot be selected")
    var interleaved = AppleVoicePacketLog(address: address, startedAt: 0)!
    _ = interleaved.receive(connected() + first, now: 0)
    check(interleaved.receive(acl(Array(body.dropFirst(40)), boundary: 1, handle: 0x52), now: 0).isEmpty,
          "foreign ACL cannot complete a selected fragment")
    check(interleaved.receive(last, now: 0) == [.report(payload, newStream: true)], "selected continuation remains intact")
    var reused = AppleVoicePacketLog(address: address, startedAt: 0)!
    _ = reused.receive(connected() + first, now: 0)
    check(reused.receive(connected(foreign: true) + last, now: 0) == [.reset] && reused.stopped,
          "foreign handle reuse closes old identity before any audio")
    var disconnected = AppleVoicePacketLog(address: address, startedAt: 0)!
    _ = disconnected.receive(connected() + first, now: 0)
    let end = record(1, [5, 4, 0, 0x51, 0, 0x13])
    check(disconnected.receive(end + last, now: 0) == [.reset] && disconnected.stopped,
          "disconnect invalidates buffered voice and ends capture")
    var enhanced = AppleVoicePacketLog(address: address, startedAt: 0)!
    check(enhanced.receive(connected(enhanced: true) + first + last, now: 0).last == .report(payload, newStream: true),
          "enhanced LE connection events also bind the exact peer")
    var sendOnly = AppleVoicePacketLog(address: address, startedAt: 0)!
    _ = sendOnly.receive(connected(), now: 0)
    var send = acl(body); send[12] = 2
    check(sendOnly.receive(send, now: 0).isEmpty, "sent ACL never becomes microphone audio")
    var repeated = AppleVoicePacketLog(address: address, startedAt: 0)!
    _ = repeated.receive(connected() + acl(body, tick: 1), now: 0)
    check(repeated.receive(acl(body, tick: 1), now: 0).isEmpty, "same record cannot repeat speech")
    check(repeated.receive(connected() + acl(body, tick: 1), now: 0) == [.reset],
          "connection snapshot reset cannot bypass duplicate history")
    check(repeated.receive(acl(body, tick: 0), now: 0) == [.reset], "timestamp ordering remains enforced without wall-clock assumption")
    var dynamic = AppleVoicePacketLog(address: address, startedAt: 0)!
    _ = dynamic.receive(connected(), now: 0)
    check(dynamic.receive(acl(pdu(payload, attr: 0x137)), now: 0) == [.report(payload, newStream: true)],
          "binary transport preserves dynamic ATT attributes")
    let zero = Data(repeating: 0, count: 99)
    check(dynamic.receive(acl(pdu(zero, attr: 0x35), tick: 1), now: 0).isEmpty,
          "unrelated zero notification cannot terminate active speech")
    check(dynamic.receive(acl(pdu(zero, attr: 0x137), tick: 2), now: 0) == [.report(zero, newStream: false)],
          "matching fresh end notification reaches decoder reset")
    for malformed in [Data([0, 0, 0, 8]), Data([255, 255, 255, 255]), record(1, [5, 0, 0]),
                      record(3, [], tick: 1_000_000)] {
        var parser = AppleVoicePacketLog(address: address, startedAt: 0)!
        check(parser.receive(malformed, now: 0) == [.reset] && parser.stopped,
              "corrupt binary framing fails closed rather than guessing alignment")
        check(parser.receive(all, now: 0).isEmpty && parser.bufferedBytes == 0, "failed session cannot be revived by later valid data")
    }
    var truncated = AppleVoicePacketLog(address: address, startedAt: 0)!
    _ = truncated.receive(Data(all.dropLast()), now: 0)
    truncated.finish()
    check(truncated.diagnostics.partialBytesAtEOF > 0 && truncated.bufferedBytes == 0,
          "truncated file is diagnosed and discarded at EOF")
    for now in [-1, 23.001, Double.infinity, Double.nan] {
        var parser = AppleVoicePacketLog(address: address, startedAt: 0)!
        check(parser.receive(all, now: now) == [.reset] && parser.stopped, "monotonic session lifetime remains bounded")
    }
    var huge = AppleVoicePacketLog(address: address, startedAt: 0)!
    check(huge.receive(Data(repeating: 0, count: 65537), now: 0) == [.reset], "oversized ingress bounded before buffering")
    check(AppleVoicePacketLog(address: "not-a-device", startedAt: 0) == nil, "invalid selected identity rejected")
    let decoder = try AppleVoiceDecoder()
    var integrated = AppleVoicePacketLog(address: address, startedAt: 0)!
    var samples = 0
    for event in integrated.receive(all, now: 0) {
        switch event {
        case .reset: try decoder.reset()
        case let .report(value, newStream):
            if newStream { try decoder.reset() }
            samples += try decoder.consume(reportID: 0xFA, payload: value).count
        }
    }
    check(samples == 960, "binary connection plus fragments reach real Opus decoder")
}
