import Foundation

func checkAppleVoiceTransport() throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fixture = try String(contentsOfFile: "Tests/Fixtures/apple-packetlogger26-synthetic.tsv", encoding: .utf8)
    let actual = fixture.split(separator: "\n").map(String.init).last!
    let columns = actual.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    let now = formatter.date(from: columns[0])!
    var transport = AppleVoiceTransport(address: "11:22:33:44:55:66")
    let expected = report(0)
    check(transport.receive(actual, now: now) == .report(expected, newStream: true), "actual PacketLogger conversion format and address binding")
    check(transport.receive(actual, now: now) == .report(expected, newStream: false), "same stream does not reset codec on each packet")
    func changed(_ index: Int, _ value: String) -> String {
        var fields = columns; fields[index] = value
        return fields.joined(separator: "\t")
    }
    for (index,value) in [(2,"22:33:44:55:66:77"),(2,""),(4,"SEND"),(1,"ACL Send"),(6,"unexpected")]
    { check(transport.receive(changed(index,value),now: now) == nil, "unrelated device/direction/format never yields audio") }
    check(transport.receive(actual, now: now.addingTimeInterval(1)) == .reset, "old trace is not replayed")
    check(transport.receive(actual, now: now.addingTimeInterval(-1)) == .reset, "future trace rejected")
    check(transport.receive(changed(0,"not a date"), now: now) == .reset, "bad timestamp fails closed")
    check(transport.receive(changed(3,"0x0407"), now: now) == .reset, "printed and raw connection handles must agree")
    check(transport.receive(String(repeating:"x",count:8193),now:now) == .reset, "bounded line parser")
    var raw = columns[5].split(separator:" ").map(String.init)
    raw[2] = "28" // actual PacketLogger reassembly keeps first fragment length
    check(transport.receive(changed(5,raw.joined(separator:" ")),now:now) == .report(expected,newStream:true), "reassembled packet retains first ACL fragment length")
    for (index,value) in [(0,"07"),(1,"64"),(2,"FF"),(4,"65"),(6,"05"),(8,"1D"),(9,"00")]
    {
        var broken = raw; broken[index] = value
        let result = transport.receive(changed(5,broken.joined(separator:" ")),now:now)
        if case .report? = result { check(false,"invalid ACL/L2CAP/ATT cannot produce report") }
        else { check(true,"invalid transport rejected") }
    }
    check(transport.receive(changed(5,"ZZ " + columns[5]),now:now) == .reset,"malformed hex rejected")
    check(transport.receive(actual, now: now) == .report(expected,newStream:true), "reset requires new codec stream")
    let earlier = formatter.string(from: now.addingTimeInterval(-0.01))
    check(transport.receive(changed(0,earlier),now:now) == .reset,"out of order timestamps reset stream")
    for size in 0..<110 {
        let result = transport.receive(changed(5,raw.prefix(size).joined(separator:" ")),now:now)
        if case .report? = result { check(false,"truncated raw transport rejected") }
        else { check(true,"truncated raw transport rejected") }
    }

    // Diagnostics must distinguish transport failures without recording even an
    // unknown packet type or bytes belonging to another Bluetooth device.
    func counts(_ line: String, at time: Date? = nil) throws -> [String: Int] {
        var candidate = AppleVoiceTransport(address: "11:22:33:44:55:66")
        _ = candidate.receive(line, now: time ?? now)
        let encoded = try JSONEncoder().encode(candidate.diagnostics)
        let result = try JSONSerialization.jsonObject(with: encoded) as! [String: Int]
        check(result.count == 25 && result["lines"] == 1, "fixed numeric-only diagnostics schema")
        check(!String(decoding: encoded, as: UTF8.self).contains("11:22:33:44:55:66"), "diagnostics never include selected address")
        return result
    }
    let validCounts = try counts(actual)
    check(validCounts["reportEnvelopes"] == 1 && validCounts["audioFrameReports"] == 1 && validCounts["endReports"] == 0,
          "audio envelope and structurally valid frame counted separately")
    check(validCounts["selectedDeviceLines"] == 1 && validCounts["attReceiveLines"] == 1,
          "selected receive and ATT progress counted")
    let empty = AppleVoiceTransport(address: "11:22:33:44:55:66")
    check(empty.diagnostics.lines == 0 && empty.diagnostics.reportEnvelopes == 0, "zero input remains distinguishable")
    check(try counts("not a PacketLogger line")["malformedFormatLines"] == 1, "unknown text counts only as format failure")
    check(try counts(changed(6,"unexpected"))["malformedFormatLines"] == 1, "extra column content is not accepted")
    check(try counts(changed(4,"SEND"))["nonReceiveLines"] == 1, "send direction has its own counter")
    var foreign = columns
    foreign[0] = "invalid private timestamp"; foreign[2] = "22:33:44:55:66:77"; foreign[5] = "ZZ private payload"
    let foreignCounts = try counts(foreign.joined(separator: "\t"))
    check(foreignCounts["otherDeviceLines"] == 1 && foreignCounts["selectedDeviceLines"] == 0 &&
          foreignCounts["invalidTimestamps"] == 0 && foreignCounts["malformedHexLines"] == 0,
          "non-target traffic is counted without inspecting its content")
    check(try counts(changed(0,"not a date"))["invalidTimestamps"] == 1, "invalid timestamp diagnosis")
    check(try counts(actual,at:now.addingTimeInterval(1))["staleOrFutureTimestamps"] == 1, "stale timestamp diagnosis")
    check(try counts(actual,at:now.addingTimeInterval(-1))["staleOrFutureTimestamps"] == 1, "future timestamp diagnosis")
    check(try counts(changed(5,"ZZ"))["malformedHexLines"] == 1, "malformed raw hex diagnosis")
    check(try counts(changed(1,"ACL Receive"))["unrelatedPacketTypes"] == 1, "unrecognized packet type counted without its name")
    check(try counts(changed(5,"00"))["unrecognizedATTShape"] == 1, "different ATT shape distinguished from no packets")
    check(try counts(changed(3,"not a handle"))["unrecognizedATTShape"] == 1, "invalid printed handle shape diagnosis")
    check(try counts(changed(3,"0x0407"))["invalidTransportHeaders"] == 1, "handle mismatch diagnosis")
    check(try counts(String(repeating:"x",count:8193))["oversizedLines"] == 1, "oversized line diagnosis")
    var otherATT = columns[5].split(separator:" ").map(String.init)
    otherATT[9] = "00"
    check(try counts(changed(5,otherATT.joined(separator:" ")))["unrelatedATTValues"] == 1, "invalid zero ATT handle counted separately")
    var malformedAudio = columns[5].split(separator:" ").map(String.init)
    malformedAudio[15] = "00"
    let malformedCounts = try counts(changed(5,malformedAudio.joined(separator:" ")))
    check(malformedCounts["reportEnvelopes"] == 1 && malformedCounts["malformedAudioReports"] == 1 &&
          malformedCounts["audioFrameReports"] == 0, "envelope is not falsely counted as valid audio")
    let endRaw = columns[5].split(separator:" ").prefix(11).map(String.init) + Array(repeating:"00",count:99)
    let endCounts = try counts(changed(5,endRaw.joined(separator:" ")))
    check(endCounts["endReports"] == 0 && endCounts["unboundEndReports"] == 1 && endCounts["audioFrameReports"] == 0 && endCounts["malformedAudioReports"] == 0,
          "zero sentinel cannot identify a voice stream without a prior valid frame")
    var hci = columns; hci[1] = "HCI Event"; hci[5] = "05 04 00 07 04 13"
    let disconnectCounts = try counts(hci.joined(separator:"\t"))
    check(disconnectCounts["hciEventLines"] == 1 && disconnectCounts["disconnectEvents"] == 1,
          "selected disconnect diagnosis")
    hci[5] = "0E 00"
    let hciCounts = try counts(hci.joined(separator:"\t"))
    check(hciCounts["hciEventLines"] == 1 && hciCounts["disconnectEvents"] == 0,
          "other HCI event never mistaken for disconnect")
    var ordered = AppleVoiceTransport(address:"11:22:33:44:55:66")
    _ = ordered.receive(actual,now:now)
    _ = ordered.receive(changed(0,earlier),now:now)
    check(ordered.diagnostics.outOfOrderTimestamps == 1 && ordered.diagnostics.lines == 2,
          "out of order diagnosis survives stream reset")
    ordered.reset()
    check(ordered.diagnostics.reportEnvelopes == 1 && ordered.diagnostics.outOfOrderTimestamps == 1,
          "stream reset does not erase experiment totals")
}
