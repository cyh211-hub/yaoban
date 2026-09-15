// GPL-3.0. Bounded reconstruction of the A2854 layout verified in the Forge trial.
// Pure protocol code: no capture, IO, identity discovery, or clock conversion.
import Foundation

struct AppleVoiceACLReassembler {
    struct Value: Equatable {
        let attribute: UInt16
        let payload: Data
    }
    struct Diagnostics: Encodable {
        var packets = 0
        var otherConnections = 0
        var invalidPackets = 0
        var expiredFragments = 0
        var orphanContinuations = 0
        var replacedStarts = 0
        var invalidNotifications = 0
        var completedValues = 0
    }

    // Caller must establish this handle from the selected device in the current
    // connection, before accepting data. Never learn device identity from audio.
    let selectedHandle: UInt16
    private(set) var diagnostics = Diagnostics()
    private(set) var bufferedBytes = 0
    private var pending: [UInt8]?
    private var beganAt: TimeInterval?
    private var lastArrival: TimeInterval?
    static let fragmentLifetime: TimeInterval = 0.25

    init?(selectedHandle: UInt16) {
        guard selectedHandle <= 0x0EFF else { return nil }
        self.selectedHandle = selectedHandle
    }

    mutating func reset() {
        pending = nil; beganAt = nil; bufferedBytes = 0
        // Resetting a PDU does not permit a backwards monotonic arrival clock.
    }

    // Exactly one *received*, unmodified HCI ACL packet, including its 4-byte
    // header. Arrival time comes from the caller's monotonic clock. This layer
    // does not authenticate a capture session or replace its freshness checks.
    mutating func receive(_ packet: Data, now: TimeInterval) -> Value? {
        diagnostics.packets += 1
        guard now.isFinite, now >= 0,
              lastArrival.map({ now >= $0 }) ?? true else {
            diagnostics.invalidPackets += 1; reset(); return nil
        }
        lastArrival = now
        if let beganAt, now - beganAt > Self.fragmentLifetime {
            diagnostics.expiredFragments += 1; reset()
        }
        guard (4...110).contains(packet.count) else {
            diagnostics.invalidPackets += 1; reset(); return nil
        }
        let bytes = Array(packet)
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        let header = u16(0), handle = header & 0x0FFF
        guard handle == selectedHandle else {
            diagnostics.otherConnections += 1; return nil
        }
        let boundary = (header >> 12) & 3
        guard header & 0xC000 == 0, boundary != 3,
              Int(u16(2)) == bytes.count - 4, bytes.count > 4 else {
            diagnostics.invalidPackets += 1; reset(); return nil
        }
        let body = Array(bytes.dropFirst(4))
        if boundary == 0 || boundary == 2 {
            if pending != nil { diagnostics.replacedStarts += 1 }
            reset()
            // ATT notification: opcode 1 + attribute 2 + verified report 99.
            guard body.count >= 4, body[0] == 102, body[1] == 0,
                  body[2] == 4, body[3] == 0 else {
                diagnostics.invalidPackets += 1; return nil
            }
            pending = body; beganAt = now
        } else {
            guard var accumulated = pending else {
                diagnostics.orphanContinuations += 1; return nil
            }
            guard accumulated.count + body.count <= 106 else {
                diagnostics.invalidPackets += 1; reset(); return nil
            }
            accumulated.append(contentsOf: body); pending = accumulated
        }
        bufferedBytes = pending?.count ?? 0
        guard let complete = pending, complete.count == 106 else { return nil }
        reset()
        let attribute = UInt16(complete[5]) | UInt16(complete[6]) << 8
        let payload = Data(complete.dropFirst(7))
        guard complete[4] == 0x1B, attribute != 0,
              AppleVoiceReport.parse(reportID: 0xFA, payload: payload) != nil else {
            diagnostics.invalidNotifications += 1; return nil
        }
        diagnostics.completedValues += 1
        // A zero-filled end report is a valid *shape*. The caller must still
        // reject it unless it belongs to the currently active voice attribute.
        return Value(attribute: attribute, payload: payload)
    }
}
