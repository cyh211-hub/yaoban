// GPL-3.0. Shape-only diagnostics for selected-device receive lines. No decoding,
// buffering, address/handle logging, or changes to transport acceptance rules.
import Foundation

struct AppleVoiceWireDiagnostics: Encodable {
    var inspectedSelectedPackets = 0
    var validHexPackets = 0
    var completeVoiceCandidates = 0
    var fragmentedVoiceCandidates = 0
    var aclContinuationCandidates = 0
    var voiceCandidatesOutsideATTLabel = 0

    mutating func observe(hex: String, displayedHandle: String, packetType: String) {
        inspectedSelectedPackets += 1
        // This observer runs before the timestamp gate so a rejected clock cannot
        // conceal packet shape. It must only be called after exact-device and
        // direction checks. Candidate counts never mean fresh or decoded audio.
        guard hex.utf8.count <= 8192 else { return }
        let words = hex.split(separator: " ")
        guard !words.isEmpty, words.count <= 2048,
              words.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else { return }
        let bytes = words.compactMap { UInt8($0, radix: 16) }
        validHexPackets += 1
        guard bytes.count >= 5, bytes.count <= 110, displayedHandle.hasPrefix("0x"),
              let displayed = UInt16(displayedHandle.dropFirst(2), radix: 16) else { return }
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        let header = u16(0), connection = header & 0x0FFF, boundary = (header >> 12) & 3
        guard connection <= 0x0EFF, connection == displayed, header & 0xC000 == 0 else { return }
        if boundary == 1 {
            // Without an accepted first fragment this is only an ACL-shape
            // candidate, not evidence that the continuation contains speech.
            if Int(u16(2)) == bytes.count - 4 { aclContinuationCandidates += 1 }
            return
        }
        guard [0, 2].contains(boundary), bytes.count >= 17,
              u16(4) == 102, u16(6) == 4, bytes[8] == 0x1B, u16(9) != 0 else { return }
        let candidate: Bool
        if bytes.count == 110 {
            // Match the complete shape already accepted by the transport,
            // including offline reassembly preserving the first ACL length.
            guard (4...106).contains(u16(2)) else { return }
            if case .frame? = AppleVoiceReport.parse(reportID: 0xFA, payload: Data(bytes.dropFirst(11))) {
                completeVoiceCandidates += 1; candidate = true
            } else { candidate = false }
        } else {
            guard Int(u16(2)) == bytes.count - 4,
                  (2...94).contains(bytes[15]), bytes[16] == 0xB8 else { return }
            fragmentedVoiceCandidates += 1; candidate = true
        }
        if candidate && packetType != "ATT Receive" { voiceCandidatesOutsideATTLabel += 1 }
    }
}
