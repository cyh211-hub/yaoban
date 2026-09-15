import Foundation

var checks = 0
func check(_ value: Bool, _ reason: String) {
    checks += 1
    precondition(value, reason)
}
func report(_ sequence: UInt16, _ packet: [UInt8] = [0xB8, 0xFF, 0xFE]) -> Data {
    precondition((1...94).contains(packet.count))
    var bytes = [UInt8](repeating: 0, count: 99)
    bytes[2] = UInt8(truncatingIfNeeded: sequence)
    bytes[3] = UInt8(truncatingIfNeeded: sequence >> 8)
    bytes[4] = UInt8(packet.count)
    bytes.replaceSubrange(5..<(5 + packet.count), with: packet)
    return Data(bytes)
}
let valid = report(0xABCD)
check(AppleVoiceReport.parse(reportID: 0xFA, payload: valid) == .frame(sequence: 0xABCD, opus: Data([0xB8, 0xFF, 0xFE])), "sequence endianness and packet extraction")
check(AppleVoiceReport.parse(reportID: 0xFB, payload: valid) == nil, "other HID report is not audio")
check(AppleVoiceReport.parse(reportID: 0xFA, payload: Data(repeating: 0, count: 99)) == .ended, "full release sentinel")
for length in [0, 1, 4, 5, 6, 98, 100, 4096] {
    check(AppleVoiceReport.parse(reportID: 0xFA, payload: Data(repeating: 0, count: length)) == nil, "reject truncated or oversized values, including apparent release")
}
for length in [0, 1, 95, 255] {
    var bad = valid; bad[4] = UInt8(length)
    check(AppleVoiceReport.parse(reportID: 0xFA, payload: bad) == nil, "declared packet length bounds")
}
for toc: UInt8 in [0, 0xB9, 0xBC, 0xF8] {
    var bad = valid; bad[5] = toc
    check(AppleVoiceReport.parse(reportID: 0xFA, payload: bad) == nil, "unverified codec profile rejected")
}
var prefixed = valid; prefixed[0] = 0xA5; prefixed[1] = 0xC3; prefixed[98] = 0x37
check(AppleVoiceReport.parse(reportID: 0xFA, payload: prefixed) == AppleVoiceReport.parse(reportID: 0xFA, payload: valid), "non-codec prefix and padding excluded")
check(AppleVoiceReport.parse(reportID: 0xFA, payload: report(1, [0xB8] + Array(repeating: 0, count: 93))) != nil, "largest valid packet boundary")
let sliced = (Data([0x80]) + valid).dropFirst()
check(AppleVoiceReport.parse(reportID: 0xFA, payload: sliced) == AppleVoiceReport.parse(reportID: 0xFA, payload: valid), "Data slice index need not begin at zero")

var order = AppleVoiceSequence()
check(order.receive(65534) == .first, "start accepts arbitrary sequence")
check(order.receive(65534) == .discard, "duplicate rejected")
check(order.receive(65533) == .discard, "older packet rejected")
check(order.receive(65535) == .decode(conceal: 0), "duplicate cannot advance state")
check(order.receive(0) == .decode(conceal: 0), "sequence wraps")
check(order.receive(5) == .decode(conceal: 4), "small gap bounded concealment")
check(order.receive(20) == .resync, "large gap resets instead of backlog")
check(order.receive(21) == .decode(conceal: 0), "large gap resumes normally")
order.reset()
check(order.receive(0) == .first, "explicit reset accepts new utterance")

let decoder = try AppleVoiceDecoder()
guard let encoder = yb_voice_test_encoder() else { fatalError("cannot create synthetic encoder") }
var frames: [Data] = []
for index in 0..<12 {
    var bytes = [UInt8](repeating: 0, count: 94)
    let count = yb_voice_test_frame(encoder, Int32(index), &bytes, Int32(bytes.count))
    check((1...94).contains(count) && bytes[0] == 0xB8, "synthetic fixture matches observed codec profile")
    frames.append(report(UInt16(index), Array(bytes.prefix(Int(count)))))
}
opus_encoder_destroy(encoder)
var pcm: [Int16] = []
for data in frames {
    let result = try decoder.consume(reportID: 0xFA, payload: data)
    check(result.count == 960, "one audio report produces exactly 20 ms at 48 kHz")
    pcm += result
}
let rms = sqrt(pcm.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(pcm.count))
check(rms > 1000 && rms < 10000, "decoded synthetic tone is non-silent and bounded")
let steady = Array(pcm.dropFirst(1920))
let crossings = zip(steady, steady.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
let frequency = Double(crossings) * 48000 / Double(steady.count)
check(abs(frequency - 440) < 10, "decoded tone retains 440 Hz pitch after codec warm-up")
check(try decoder.consume(reportID: 0xFA, payload: frames.last!).isEmpty, "duplicate emits no repeated speech")
check(try decoder.consume(reportID: 0xFA, payload: frames[0]).isEmpty, "late speech discarded")
try decoder.reset()
check(try decoder.consume(reportID: 0xFA, payload: frames[0]).count == 960, "utterance reset works")
check(try decoder.consume(reportID: 0xFA, payload: frames[3]).count == 2880, "two missing frames plus real frame")
check(try decoder.consume(reportID: 0xFA, payload: frames[11]).count == 960, "long gap never returns stale concealment burst")
try decoder.reset()
_ = try decoder.consume(reportID: 0xFA, payload: frames[0])
check(try decoder.consume(reportID: 0xFA, payload: frames[5]).count == 4800, "maximum concealment output remains bounded")
check(try decoder.consume(reportID: 0xFA, payload: Data(repeating: 0, count: 99)).isEmpty, "release emits no sound")
let restarted = try decoder.consume(reportID: 0xFA, payload: frames[0])
let fresh = try AppleVoiceDecoder().consume(reportID: 0xFA, payload: frames[0])
check(restarted == fresh, "release clears codec memory as well as sequence")
check(try decoder.consume(reportID: 0xFA, payload: frames[0].dropLast()).isEmpty, "bad packet is rejected before codec")
check(try decoder.consume(reportID: 0xFB, payload: frames[1]).isEmpty, "keyboard report never reaches decoder")
check(try decoder.consume(reportID: 0xFA, payload: frames[1]).count == 960, "invalid reports do not reset or advance stream")

// Deterministic malformed-input coverage. No live capture or private voice fixtures.
var random: UInt64 = 0xA2854
func next() -> UInt8 {
    random = random &* 6364136223846793005 &+ 1442695040888963407
    return UInt8(truncatingIfNeeded: random >> 32)
}
for iteration in 0..<10000 {
    let length = iteration % 140
    var bytes = (0..<length).map { _ in next() }
    if length == 99 && iteration.isMultiple(of: 3) { bytes[5] = 0xB8; bytes[4] = 1 + next() % 94 }
    let data = Data(bytes)
    if case let .frame(_, packet)? = AppleVoiceReport.parse(reportID: 0xFA, payload: data) {
        check((2...94).contains(packet.count) && packet.first == 0xB8, "fuzz accepted frame stays bounded")
    }
    do {
        let result = try decoder.consume(reportID: 0xFA, payload: data)
        check(result.count <= 4800 && result.count.isMultiple(of: 960), "fuzz output bounded to one frame plus at most four PLC frames")
    } catch { try decoder.reset() }
}
try checkAppleVoiceTransport()
checkAppleVoiceTimingDiagnostics()
try checkAppleVoiceSessionTiming()
try checkAppleVoiceHandleCompatibility()
try checkAppleVoiceWireDiagnostics()
try checkAppleVoiceACLReassembly()
try checkAppleVoicePacketLog()
try checkAppleVoiceAddressedCapture()
print("PASS: \(checks) Apple voice lab checks; synthetic tone RMS \(Int(rms)); no Bluetooth capture or audio devices opened")

for duration in [-1.0, 0, 66, Double.infinity, Double.nan] {
    check(AppleVoiceAddressedCapture(address: "AA:BB:CC:DD:EE:FF", startedAt: 0, duration: duration) == nil, "invalid session duration rejected")
}
var productDeadline = AppleVoiceAddressedCapture(address: "AA:BB:CC:DD:EE:FF", startedAt: 0, duration: 65)!
_ = productDeadline.receive("", now: 65.01)
check(productDeadline.stopped, "product capture cannot outlive 65 seconds")
print("PASS: product duration bounds")
