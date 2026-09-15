import Foundation

func checkAppleVoiceAddressedCapture() throws {
    let address = "11:22:33:44:55:66"
    let payload = report(12)
    let body: [UInt8] = [102, 0, 4, 0, 0x1B, 0x37, 0] + payload
    func line(_ bytes: [UInt8], address: String = "11:22:33:44:55:66", handle: String = "0x0051", tick: String = "001", kind: String = "Unclassified synthetic receive", direction: String = "RECV") -> String {
        ["2026-09-13T08:00:00.\(tick)Z", kind, address, handle, direction,
         bytes.map { String(format: "%02X", $0) }.joined(separator: " "), ""].joined(separator: "\t")
    }
    func acl(_ body: [UInt8], pb: UInt16 = 2) -> [UInt8] {
        let header: UInt16 = 0x51 | pb << 12
        return [UInt8(truncatingIfNeeded: header), UInt8(header >> 8), UInt8(body.count), 0] + body
    }
    for cut in 4..<body.count {
        var parser = AppleVoiceAddressedCapture(address: address, startedAt: 1)!
        check(parser.receive(line(acl(Array(body.prefix(cut)))), now: 1) == nil, "addressed first fragment awaits continuation")
        check(parser.receive(line(acl(Array(body.dropFirst(cut)), pb: 1), tick: "002"), now: 1.01) == .report(payload, newStream: true),
              "already connected device decodes without a new LE connection event")
    }
    // A selected-device status record can establish source readiness before
    // Feature activation; it must never be decoded or mistaken for voice.
    var status = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
    check(status.receive(line([1, 2], handle: "----"), now: 0) == .reset,
          "non-ACL status retains strict audio rejection")
    check(status.diagnostics.selectedAddressRecords == 1 && status.diagnostics.selectedPackets == 0 && status.diagnostics.reports == 0,
          "bound address metadata permits activation without requiring voice-shaped data first")
    check(status.diagnostics.missingACLHeader == 1, "source/packet failures are diagnosed separately")
    var foreignStatus = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
    _ = foreignStatus.receive(line([1, 2], address: "00:00:00:00:00:00", handle: "----"), now: 0)
    check(foreignStatus.diagnostics.selectedAddressRecords == 0, "foreign status cannot mark source ready")
    var full = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
    var expanded = acl(body); expanded[2] = 40
    check(full.receive(line(expanded), now: 0) == .report(payload, newStream: true), "exact Apple expanded PDU normalized despite original first-fragment length")
    check(full.receive(line(expanded), now: 0) == nil && full.diagnostics.duplicateReports == 1, "expanded duplicate cannot repeat speech")
    var selected = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
    check(selected.receive(line(acl(body), address: "00:00:00:00:00:00"), now: 0) == nil, "foreign valid Opus cannot establish device identity")
    check(selected.receive(line(acl(body), direction: "SEND"), now: 0) == nil, "TX cannot become microphone audio")
    check(selected.receive(line(acl(body), handle: "0x0052"), now: 0) == .reset, "displayed identity handle must match raw transport")
    check(selected.diagnostics.selectedPackets == 0, "invalid transport or foreign packets cannot be accepted as selected ACL")
    var interleaved = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
    _ = interleaved.receive(line(acl(Array(body.prefix(40)))), now: 0)
    check(interleaved.receive(line(acl(Array(body.dropFirst(40)), pb: 1), address: "00:00:00:00:00:00"), now: 0) == nil,
          "every continuation needs selected address")
    check(interleaved.receive(line(acl(Array(body.dropFirst(40)), pb: 1), tick: "002"), now: 0) == .report(payload, newStream: true), "foreign continuation leaves selected state intact")
    check(interleaved.receive(line(acl(body), tick: "000"), now: 0) == .reset && interleaved.diagnostics.outOfOrder == 1, "relative timestamp order enforced without wall-clock correction")
    var ended = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
    let zero = [UInt8](repeating: 0, count: 99)
    let zeroBody: [UInt8] = [102, 0, 4, 0, 0x1B, 0x37, 0] + zero
    check(ended.receive(line(acl(zeroBody)), now: 0) == nil, "zero cannot establish voice")
    _ = ended.receive(line(acl(body), tick: "002"), now: 0)
    check(ended.receive(line(acl(zeroBody), tick: "003"), now: 0) == .report(Data(zero), newStream: false), "bound end recognized")
    var disconnected = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
    _ = disconnected.receive(line(acl(body)), now: 0)
    check(disconnected.receive(line([5,4,0,0x51,0,0x13], kind: "HCI Event"), now: 0) == .reset && disconnected.stopped, "selected disconnect stops addressed capture")
    for now in [-1.0, 23.01, Double.nan, Double.infinity] {
        var parser = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
        check(parser.receive(line(acl(body)), now: now) == .reset && parser.stopped, "session lifetime remains bounded")
    }
    var invalid = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
    var bad = expanded; bad[15] = 0
    check(invalid.receive(line(bad), now: 0) == .reset, "malformed expanded envelope cannot be normalized")
    check(invalid.receive(String(repeating: "x", count: 8193), now: 0) == .reset && invalid.stopped, "oversized line closes session")
    var decode = AppleVoiceAddressedCapture(address: address, startedAt: 0)!
    let decoder = try AppleVoiceDecoder()
    if case let .report(data, _) = decode.receive(line(expanded), now: 0) {
        check(try decoder.consume(reportID: 0xFA, payload: data).count == 960, "addressed reconstructed frame reaches real Opus decoder")
    } else { check(false, "expected reconstructed voice") }
}
