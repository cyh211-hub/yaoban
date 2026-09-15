import Foundation

func checkAppleVoiceSessionTiming() throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Independent epoch from the synthetic .pklg binary header, not derived
    // from the timestamp string under test. No recorded Bluetooth data here.
    let epoch = Date(timeIntervalSince1970: 1789210176.02)
    for value in ["2026-09-12T18:49:36.020+08:00", "2026-09-12T10:49:36.020Z",
                  "2026-09-12T06:49:36.020-04:00"] {
        check(abs(formatter.date(from: value)!.timeIntervalSince(epoch)) < 0.0001, "PacketLogger ISO8601 respects explicit timezone against independent epoch")
    }
    let fixture = try String(contentsOfFile: "Tests/Fixtures/apple-packetlogger26-synthetic.tsv", encoding: .utf8)
    let fields = fixture.split(separator: "\n").last!.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    check(abs(formatter.date(from: fields[0])!.timeIntervalSince(epoch)) < 0.0001, "actual offline converter timestamp agrees with known binary epoch")
    func line(_ offset: TimeInterval, address: String = "11:22:33:44:55:66") -> String {
        var value = fields
        value[0] = formatter.string(from: epoch.addingTimeInterval(offset)); value[2] = address
        return value.joined(separator: "\t")
    }
    let clock = AppleVoiceSessionClock(startedAt: epoch, monotonicStart: 100)
    check(clock.date(at: 100) == epoch, "clock uses one explicit session anchor")
    check(clock.date(at: 105) == epoch.addingTimeInterval(5), "later wall-clock changes are not consulted")
    check(clock.date(at: 123) == epoch.addingTimeInterval(23), "last bounded moment remains valid")
    for invalid in [99.9, 123.001, Double.nan, Double.infinity, -Double.infinity] {
        check(clock.date(at: invalid) == nil, "invalid or expired monotonic interval rejected")
    }
    var bounded = AppleVoiceTransport(address: "11:22:33:44:55:66", sessionStartedAt: epoch)
    check(bounded.receive(line(1), now: clock.date(at: 105)!) == .report(report(0), newStream: true), "delayed batch from current session accepted")
    check(bounded.timingDiagnostics.timestampPastSamples == 1 && bounded.timingDiagnostics.timestampPastMaxMilliseconds == 4000,
          "delay is diagnosed without storing timestamp or packet")
    check(bounded.receive(line(-1), now: clock.date(at: 105)!) == .reset, "pre-session history rejected even after a valid batch")
    check(bounded.receive(line(5.2), now: clock.date(at: 105)!) == .reset, "future data rejected")
    bounded.reset()
    check(bounded.receive(line(-3600), now: clock.date(at: 105)!) == .reset, "codec reset cannot rebase capture to historical data")
    check(bounded.receive(line(2), now: clock.date(at: 110)!) == .report(report(0), newStream: true), "valid current-session data survives reset")
    check(bounded.receive(line(3), now: epoch.addingTimeInterval(24)) == .reset, "session expiry enforced by transport too")
    check(bounded.receive(line(1, address: "22:33:44:55:66:77"), now: clock.date(at: 105)!) == nil, "binding isolation precedes new timing logic")
    check(bounded.timingDiagnostics.timestampPastSamples + bounded.timingDiagnostics.timestampFutureSamples == bounded.diagnostics.selectedDeviceLines,
          "every selected valid timestamp contributes exactly one lag direction")
    check(bounded.diagnostics.attReceiveLines == bounded.diagnostics.selectedDeviceLines,
          "ATT classification remains visible even for rejected timing")
    var liveDefault = AppleVoiceTransport(address: "11:22:33:44:55:66")
    check(liveDefault.receive(line(1), now: clock.date(at: 105)!) == .reset, "session tolerance is explicitly opt-in for bounded lab WAV")
    for offset in [-28800.0, 28800.0] {
        var shifted = AppleVoiceTransport(address: "11:22:33:44:55:66", sessionStartedAt: epoch)
        check(shifted.receive(line(offset), now: epoch) == .reset, "hour-scale offset is never silently calibrated away")
    }
    var watermark = AppleVoiceTransport(address: "11:22:33:44:55:66", sessionStartedAt: epoch)
    let lateNow = epoch.addingTimeInterval(12)
    check(watermark.receive(line(10), now: lateNow) == .report(report(0), newStream: true), "session accepts first fresh frame")
    check(watermark.receive(line(9), now: lateNow) == .reset, "older session frame rejected once")
    check(watermark.receive(line(9), now: lateNow) == .reset, "reset cannot allow older session frame on retry")
    check(watermark.receive(line(10), now: lateNow) == nil, "same-time duplicate cannot replay through reset")
    var sameTimeFields = line(10).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    var raw = sameTimeFields[5].split(separator: " ").map(String.init)
    raw[13] = "01" // report byte 2: sequence low byte, following 11 bytes of headers
    sameTimeFields[5] = raw.joined(separator: " ")
    check(watermark.receive(sameTimeFields.joined(separator: "\t"), now: lateNow) == .report(report(1), newStream: true),
          "distinct valid frames can share PacketLogger millisecond timestamp")
    watermark.reset()
    check(watermark.receive(sameTimeFields.joined(separator: "\t"), now: lateNow) == nil, "explicit stream reset preserves same-time deduplication")
    check(watermark.diagnostics.replayedSessionReports == 2, "session replay has a separate fixed counter")
}
