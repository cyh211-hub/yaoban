// GPL-3.0. Offline A2854 research; not compiled into the installed app.
// Protocol provenance and remaining transport work: docs/2026-09-12-apple-voice-lab.md.
import Foundation

enum AppleVoiceReport: Equatable {
    case ended
    case frame(sequence: UInt16, opus: Data)

    // Input is exactly one report VALUE, excluding the HID report ID / ATT headers.
    // Fixed A2854 profile only. A new wire format must be verified before enabling it.
    static func parse(reportID: UInt8, payload: Data) -> Self? {
        guard reportID == 0xFA, payload.count == 99 else { return nil }
        let bytes = [UInt8](payload)
        if bytes.allSatisfy({ $0 == 0 }) { return .ended }
        let length = Int(bytes[4])
        guard (2...94).contains(length), bytes[5] == 0xB8 else { return nil }
        let sequence = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        // Prefix bytes and unused padding are not part of the codec packet.
        return .frame(sequence: sequence, opus: Data(bytes[5..<(5 + length)]))
    }
}

struct AppleVoiceSequence {
    enum Step: Equatable {
        case first
        case decode(conceal: Int)
        case resync
        case discard
    }
    private var expected: UInt16?

    mutating func reset() { expected = nil }

    mutating func receive(_ sequence: UInt16) -> Step {
        guard let expected else {
            self.expected = sequence &+ 1
            return .first
        }
        let gap = sequence &- expected
        // Wrap-aware ordering: duplicate / older packets must not replay speech or
        // turn an unsigned underflow into a burst of packet-loss concealment.
        guard gap < 0x8000 else { return .discard }
        self.expected = sequence &+ 1
        return gap <= 4 ? .decode(conceal: Int(gap)) : .resync
    }
}
