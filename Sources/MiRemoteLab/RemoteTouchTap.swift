import Foundation

// Pure surface-tap recognizer. The owner supplies a monotonic clock and drives
// tick at the returned/configured deadline; this type never creates a timer or
// posts input on its own.
struct RemoteTouchTap {
    private struct Contact {
        let path: Int32
        let beganAt: Double
        let x: Double
        let y: Double
        var lastAt: Double
    }
    private enum State {
        case idle
        case tracking(Contact)
        case rejectedUntilLift
    }

    private static let maximumMovement = 0.04
    private var state: State = .idle
    private var lastMessageTime: Double?
    private var pendingCount = 0
    private var deadline: Double?
    private var configuredMaximum = 0
    private var configuredInterval = 0.3
    var resolutionDeadline: Double? { deadline }

    mutating func reset() {
        state = .idle
        lastMessageTime = nil
        pendingCount = 0
        deadline = nil
        configuredMaximum = 0
        configuredInterval = 0.3
    }

    mutating func receive(_ message: RemoteTouchMessage, now: Double,
                          maxTapCount: Int, interval: Double) -> [Int] {
        guard valid(now:now,maxTapCount:maxTapCount,interval:interval) else {
            reset(); return []
        }
        guard maxTapCount > 0 else { reset(); return [] }
        if configuredMaximum != 0 &&
            (configuredMaximum != maxTapCount || configuredInterval != interval) {
            reset()
        }
        configuredMaximum = maxTapCount
        configuredInterval = interval

        switch message {
        case .ready:
            reset(); return []
        case .cancel:
            // A cancel frame means the helper observed multiple contacts or
            // an invalid contact, so no part of the sequence remains usable.
            reset(); return []
        case .reset(let time):
            guard accept(time:time,now:now) else { reset(); return [] }
            return lift(time:time,now:now,path:nil)
        case let .contact(time,path,phase,x,y):
            guard accept(time:time,now:now), validPoint(x,y), (0...7).contains(phase) else {
                reset(); return []
            }
            switch phase {
            case 3:
                var output: [Int] = []
                if case .idle = state { output = resolveIfDue(now:now) }
                guard case .idle = state else { reset(); state = .rejectedUntilLift; return output }
                state = .tracking(Contact(path:path,beganAt:time,x:x,y:y,lastAt:time))
                return output
            case 4:
                guard case .tracking(var contact) = state else { return resolveIfDue(now:now) }
                guard contact.path == path, time > contact.lastAt, time-contact.lastAt <= 0.15,
                      time-contact.beganAt <= interval,
                      hypot(x-contact.x,y-contact.y) <= Self.maximumMovement else {
                    reset(); state = .rejectedUntilLift; return []
                }
                contact.lastAt = time
                state = .tracking(contact)
                return []
            case 5, 6, 7:
                return lift(time:time,now:now,path:path,x:x,y:y)
            default:
                // In-range/hover phases can surround a real touch and must not
                // erase a completed first tap while waiting for the next one.
                guard case .idle = state else { reset(); state = .rejectedUntilLift; return [] }
                return resolveIfDue(now:now)
            }
        }
    }

    mutating func tick(now: Double) -> [Int] {
        guard now.isFinite else { reset(); return [] }
        if case .tracking(let contact) = state, now-contact.beganAt > configuredInterval {
            reset(); state = .rejectedUntilLift; return []
        }
        guard case .idle = state else { return [] }
        return resolveIfDue(now:now)
    }

    private mutating func lift(time: Double, now: Double, path: Int32?,
                               x: Double? = nil, y: Double? = nil) -> [Int] {
        switch state {
        case .idle:
            return resolveIfDue(now:now)
        case .rejectedUntilLift:
            state = .idle
            return resolveIfDue(now:now)
        case .tracking(let contact):
            guard path == nil || path == contact.path,
                  time >= contact.lastAt, time-contact.beganAt <= configuredInterval,
                  x.map({ hypot($0-contact.x,(y ?? contact.y)-contact.y) <= Self.maximumMovement }) ?? true else {
                reset(); return []
            }
            state = .idle
            pendingCount += 1
            if pendingCount >= configuredMaximum {
                let count = pendingCount
                pendingCount = 0; deadline = nil
                return [count]
            }
            deadline = now+configuredInterval
            return []
        }
    }

    private mutating func resolveIfDue(now: Double) -> [Int] {
        guard pendingCount > 0, let deadline, now >= deadline else { return [] }
        let count = pendingCount
        pendingCount = 0; self.deadline = nil
        return now-deadline <= 0.15 ? [count] : []
    }

    private mutating func accept(time: Double, now: Double) -> Bool {
        guard time.isFinite, time >= 0, now-time >= -0.02, now-time <= 0.15,
              lastMessageTime.map({ time > $0 }) ?? true else { return false }
        lastMessageTime = time
        return true
    }
    private func valid(now: Double, maxTapCount: Int, interval: Double) -> Bool {
        now.isFinite && (0...3).contains(maxTapCount) && interval.isFinite && (0.2...0.6).contains(interval)
    }
    private func validPoint(_ x: Double, _ y: Double) -> Bool {
        x.isFinite && y.isFinite && (-0.1...1.1).contains(x) && (-0.1...1.1).contains(y)
    }
}
