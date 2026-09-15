import Foundation

func checkAppleVoiceACLReassembly() throws {
    func pdu(_ value: Data, attribute: UInt16 = 0x35) -> [UInt8] {
        [102, 0, 4, 0, 0x1B, UInt8(truncatingIfNeeded: attribute), UInt8(attribute >> 8)] + value
    }
    func packet(_ body: [UInt8], boundary: UInt16 = 2, handle: UInt16 = 0x51) -> Data {
        let header = handle | boundary << 12
        return Data([UInt8(truncatingIfNeeded: header), UInt8(header >> 8),
                     UInt8(truncatingIfNeeded: body.count), UInt8(body.count >> 8)] + body)
    }
    let value = report(23), complete = pdu(value)
    for split in 4..<complete.count {
        var parser = AppleVoiceACLReassembler(selectedHandle: 0x51)!
        check(parser.receive(packet(Array(complete.prefix(split))), now: 1) == nil,
              "first fragment cannot emit partial audio")
        let result = parser.receive(packet(Array(complete.dropFirst(split)), boundary: 1), now: 1.02)
        check(result?.payload == value && result?.attribute == 0x35,
              "all legal first/continuation boundaries reconstruct one exact report")
        check(parser.bufferedBytes == 0, "completed PDU releases its bounded buffer")
    }
    for attribute: UInt16 in [0x35, 0x36, 0x137, 0xFFFF] {
        var parser = AppleVoiceACLReassembler(selectedHandle: 0x51)!
        check(parser.receive(packet(pdu(value, attribute: attribute)), now: 0)?.attribute == attribute,
              "valid notification retains dynamic attribute identity")
    }
    var parser = AppleVoiceACLReassembler(selectedHandle: 0x51)!
    let first = packet(Array(complete.prefix(40)))
    let last = packet(Array(complete.dropFirst(40)), boundary: 1)
    _ = parser.receive(first, now: 1)
    check(parser.receive(packet(Array(complete.dropFirst(40)), boundary: 1, handle: 0x52), now: 1.01) == nil,
          "another remote's continuation cannot complete selected speech")
    check(parser.receive(last, now: 1.02)?.payload == value, "foreign fragment does not contaminate selected PDU")
    _ = parser.receive(first, now: 2)
    check(parser.receive(last, now: 2.251) == nil && parser.bufferedBytes == 0,
          "expired continuation cannot resurrect an old speech prefix")
    _ = parser.receive(first, now: 3)
    check(parser.receive(last, now: 3.25)?.payload == value, "exact lifetime boundary is accepted")
    _ = parser.receive(first, now: 4)
    check(parser.receive(last, now: 3.9) == nil, "backwards arrival time clears partial state")
    check(parser.receive(last, now: 4.01) == nil, "partial state remains cleared after time recovers")
    for now in [Double.nan, Double.infinity, -Double.infinity, -1] {
        check(parser.receive(first, now: now) == nil && parser.bufferedBytes == 0,
              "non-finite and negative clocks fail closed")
    }
    var replacement = AppleVoiceACLReassembler(selectedHandle: 0x51)!
    _ = replacement.receive(first, now: 0)
    check(replacement.receive(packet(pdu(report(24)), boundary: 0), now: 0.01)?.payload == report(24),
          "new first fragment replaces interrupted PDU instead of combining utterances")
    check(replacement.receive(last, now: 0.02) == nil, "late continuation after completed replacement is orphaned")
    check(AppleVoiceACLReassembler(selectedHandle: 0xF00) == nil, "reserved connection handles rejected")
    var malformed = [Data]()
    for length in [0, 1, 3, 111, 8192] { malformed.append(Data(repeating: 0, count: length)) }
    var wrongLength = first; wrongLength[2] += 1; malformed.append(wrongLength)
    malformed.append(packet(Array(complete.prefix(40)), boundary: 3))
    malformed.append(packet(Array(complete.prefix(40)), handle: 0xC051))
    var wrongChannel = complete; wrongChannel[2] = 5; malformed.append(packet(wrongChannel))
    var wrongL2CAP = complete; wrongL2CAP[0] = 103; malformed.append(packet(wrongL2CAP))
    var wrongOpcode = complete; wrongOpcode[4] = 0x1D; malformed.append(packet(wrongOpcode))
    malformed.append(packet(pdu(value, attribute: 0)))
    var wrongCodec = value; wrongCodec[5] = 0xB9; malformed.append(packet(pdu(wrongCodec)))
    var wrongOpusLength = value; wrongOpusLength[4] = 95; malformed.append(packet(pdu(wrongOpusLength)))
    for bad in malformed {
        var invalid = AppleVoiceACLReassembler(selectedHandle: 0x51)!
        _ = invalid.receive(first, now: 0)
        check(invalid.receive(bad, now: 0.01) == nil, "invalid packet never emits audio")
        check(invalid.bufferedBytes <= 106, "malformed ingress stays memory bounded")
    }
    var overflow = AppleVoiceACLReassembler(selectedHandle: 0x51)!
    _ = overflow.receive(first, now: 0)
    check(overflow.receive(packet(Array(repeating: 1, count: 100), boundary: 1), now: 0.01) == nil,
          "oversized reassembled PDU rejected instead of truncating")
    check(overflow.bufferedBytes == 0, "overflow drops partial PDU")
    var bytewise = AppleVoiceACLReassembler(selectedHandle: 0x51)!
    _ = bytewise.receive(packet(Array(complete.prefix(4))), now: 0)
    for i in 4..<complete.count {
        let result = bytewise.receive(packet([complete[i]], boundary: 1), now: Double(i) / 1000)
        check((result != nil) == (i == complete.count - 1), "arbitrary multi-fragment split emits only at completion")
    }
    var sliced = AppleVoiceACLReassembler(selectedHandle: 0x51)!
    check(sliced.receive((Data([0xAB]) + packet(complete)).dropFirst(), now: 0)?.payload == value,
          "Data slices are interpreted without assuming zero-based indices")
    var ending = AppleVoiceACLReassembler(selectedHandle: 0x51)!
    check(ending.receive(packet(pdu(Data(repeating: 0, count: 99))), now: 0)?.payload.count == 99,
          "end-shaped notification is returned for caller's active-stream policy")
    // Real codec integration uses generated audio only, never the user's speech.
    guard let encoder = yb_voice_test_encoder() else { fatalError("encoder unavailable") }
    defer { opus_encoder_destroy(encoder) }
    let decoder = try AppleVoiceDecoder()
    var integration = AppleVoiceACLReassembler(selectedHandle: 0x51)!
    for index in 0..<8 {
        var opus = [UInt8](repeating: 0, count: 94)
        let n = yb_voice_test_frame(encoder, Int32(index), &opus, Int32(opus.count))
        let bytes = pdu(report(UInt16(index), Array(opus.prefix(Int(n)))))
        _ = integration.receive(packet(Array(bytes.prefix(40))), now: Double(index) * 0.02)
        let joined = integration.receive(packet(Array(bytes.dropFirst(40)), boundary: 1), now: Double(index) * 0.02 + 0.001)!
        check(try decoder.consume(reportID: 0xFA, payload: joined.payload).count == 960,
              "reassembled synthetic voice reaches actual Opus decoder as one 20ms frame")
    }
}
