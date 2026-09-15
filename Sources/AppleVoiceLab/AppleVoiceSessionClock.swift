import Foundation

// A single epoch anchor for this bounded WAV experiment. Later wall-clock
// adjustments and decoder resets cannot move the session's eligibility window.
struct AppleVoiceSessionClock {
    static let duration: TimeInterval = 23
    let startedAt: Date
    let monotonicStart: TimeInterval

    func date(at monotonicNow: TimeInterval) -> Date? {
        let elapsed = monotonicNow - monotonicStart
        guard startedAt.timeIntervalSince1970.isFinite, monotonicStart.isFinite,
              monotonicNow.isFinite, elapsed.isFinite,
              (0...Self.duration).contains(elapsed) else { return nil }
        return startedAt.addingTimeInterval(elapsed)
    }
}
