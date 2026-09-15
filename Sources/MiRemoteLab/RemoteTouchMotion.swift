import Foundation

enum RemoteTouchMessage: Equatable {
    case ready
    case reset(Double)
    case cancel(Double)
    case contact(time:Double, path:Int32, phase:Int, x:Double, y:Double)
    static func parse(_ line: String) -> Self? {
        guard line.utf8.count <= 200 else { return nil }
        let p = line.split(separator:" ",omittingEmptySubsequences:false)
        if p == ["READY"] { return .ready }
        guard p.count >= 2, let time = Double(p[1]), time.isFinite, time >= 0 else { return nil }
        if p.count == 2, p[0] == "R" { return .reset(time) }
        if p.count == 2, p[0] == "C" { return .cancel(time) }
        guard p.count == 6, p[0] == "T", let path = Int32(p[2]), let phase = Int(p[3]), (0...7).contains(phase),
              let x = Double(p[4]), let y = Double(p[5]), x.isFinite, y.isFinite,
              (-0.1...1.1).contains(x), (-0.1...1.1).contains(y) else { return nil }
        return .contact(time:time,path:path,phase:phase,x:x,y:y)
    }
}

struct RemoteTouchMotion {
    struct Delta: Equatable { let x:Double; let y:Double }
    enum Output: Equatable { case pointer, scroll }
    enum Direction: Equatable {
        case up, down, left, right
        var source: UInt16 {
            switch self { case .up: return 0x52; case .down: return 0x51; case .left: return 0x50; case .right: return 0x4F }
        }
    }
    enum Event: Equatable { case motion(Delta, Output), swipe(Direction) }
    struct Configuration: Equatable {
        enum Mode: Equatable { case off, pointer, scroll, swipe, hybrid }
        var mode: Mode
        // Normalized output units per second: the post-acceleration ceiling.
        var maximumPointerSpeed: Double
        var maximumScrollSpeed: Double
        var acceleration: Bool
        var ringStartRadius: Double = 0.35
        var swipeDistance: Double = 0.17
    }
    private enum Region { case inner, outer }
    private struct Contact { var time:Double; var path:Int32; var x:Double; var y:Double }

    private var acceptedTime: Double?
    private var last: Contact?
    private var start: Contact?
    private var region: Region?
    private var waitingForLift = true
    private var swipeSent = false
    private var lastAngle: Double?
    private var ringTotal = 0.0
    private var ringStarted = false
    private var ringPending = 0.0
    private var lastRingOutputTime: Double?
    // The original protocol check compiles this file alone, so its compatibility state is isolated.
    private var legacyLast: Contact?
    private var legacyWaitingForLift = true

    mutating func reset() {
        endGesture(waitForLift:true); acceptedTime = nil
        legacyLast = nil; legacyWaitingForLift = true
    }

    mutating func receive(_ message:RemoteTouchMessage, now:Double, configuration:Configuration) -> [Event] {
        guard valid(configuration), now.isFinite else { reset(); return [] }
        let timestamp: Double?
        switch message { case .ready: timestamp = nil; case .reset(let time), .cancel(let time), .contact(let time,_,_,_,_): timestamp = time }
        if let time = timestamp {
            guard fresh(time,now:now), acceptedTime.map({ time > $0 }) ?? true else { reset(); return [] }
            acceptedTime = time
        }
        switch message {
        case .ready, .cancel: reset(); return []
        case .reset(let time):
            guard fresh(time,now:now) else { reset(); return [] }
            endGesture(waitForLift:true); return []
        case let .contact(time,path,phase,x,y):
            guard fresh(time,now:now), validPoint(x,y), (0...7).contains(phase) else { reset(); return [] }
            guard phase == 3 || phase == 4 else { endGesture(waitForLift:true); return [] }
            if phase == 3 {
                guard last == nil else { endGesture(waitForLift:true); return [] }
                begin(time:time,path:path,x:x,y:y,mode:configuration.mode,ringRadius:configuration.ringStartRadius); return []
            }
            guard !waitingForLift else { return [] }
            let current = Contact(time:time,path:path,x:x,y:y)
            guard let previous = last else { return [] }
            let dt = time - previous.time
            guard previous.path == path, dt > 0, dt <= 0.15 else { endGesture(waitForLift:true); return [] }
            let dx = x-previous.x, dy = y-previous.y
            guard abs(dx) <= 0.2, abs(dy) <= 0.2 else { endGesture(waitForLift:true); return [] }
            last = current
            switch configuration.mode {
            case .off: return []
            case .pointer: return motion(dx:dx,dy:dy,dt:dt,output:.pointer,configuration:configuration)
            case .scroll: return motion(dx:dx,dy:dy,dt:dt,output:.scroll,configuration:configuration)
            case .swipe: return swipe(current,threshold:configuration.swipeDistance)
            case .hybrid:
                return region == .inner
                    ? motion(dx:dx,dy:dy,dt:dt,output:.pointer,configuration:configuration)
                    : ring(x:x,y:y,time:time,dt:dt,configuration:configuration)
            }
        }
    }

    private mutating func begin(time:Double,path:Int32,x:Double,y:Double,mode:Configuration.Mode,ringRadius:Double) {
        let contact = Contact(time:time,path:path,x:x,y:y)
        last = contact; start = contact; waitingForLift = false; swipeSent = false
        region = mode == .hybrid && hypot(x-0.5,y-0.5) >= ringRadius ? .outer : .inner
        lastAngle = region == .outer ? atan2(y-0.5,x-0.5) : nil
        ringTotal = 0; ringStarted = false; ringPending = 0; lastRingOutputTime = time
    }
    private mutating func endGesture(waitForLift:Bool) {
        last = nil; start = nil; region = nil; waitingForLift = waitForLift; swipeSent = false
        lastAngle = nil; ringTotal = 0; ringStarted = false; ringPending = 0; lastRingOutputTime = nil
    }
    private func motion(dx:Double,dy:Double,dt:Double,output:Output,configuration:Configuration) -> [Event] {
        let magnitude = hypot(dx,dy)
        guard magnitude > 0.0005 else { return [] }
        let fingerSpeed = magnitude/dt
        let gain = configuration.acceleration ? 0.75 + 2.05*smoothstep(fingerSpeed,0.10,1.25) : 1
        let ceiling = (output == .pointer ? configuration.maximumPointerSpeed : configuration.maximumScrollSpeed)*dt
        let scale = min(magnitude*gain,ceiling)/magnitude
        return [.motion(Delta(x:dx*scale,y:dy*scale),output)]
    }
    private mutating func swipe(_ current:Contact,threshold:Double) -> [Event] {
        guard !swipeSent, let start else { return [] }
        let dx = current.x-start.x, dy = current.y-start.y, ax = abs(dx), ay = abs(dy)
        guard hypot(dx,dy) >= threshold else { return [] }
        let direction: Direction
        if ax > ay*1.20 { direction = dx > 0 ? .right : .left }
        else if ay > ax*1.20 { direction = dy > 0 ? .up : .down }
        else { return [] }
        swipeSent = true; return [.swipe(direction)]
    }
    private mutating func ring(x:Double,y:Double,time:Double,dt:Double,configuration:Configuration) -> [Event] {
        // An outer-ring gesture remains a ring gesture, but the center is an angular dead zone.
        // Re-entering the ring re-anchors instead of turning center jitter into a rotation jump.
        guard hypot(x-0.5,y-0.5) >= 0.18 else { lastAngle = nil; return [] }
        let angle = atan2(y-0.5,x-0.5)
        defer { lastAngle = angle }
        guard let prior = lastAngle else { return [] }
        var radians = angle-prior
        if radians > .pi { radians -= 2 * .pi }
        if radians < -.pi { radians += 2 * .pi }
        guard abs(radians) <= .pi/2 else { return [] }
        ringTotal += radians
        if !ringStarted {
            guard abs(ringTotal) >= 0.24 else { return [] }
            ringStarted = true
            ringPending += ringTotal-(ringTotal >= 0 ? 0.24 : -0.24)
        } else { ringPending += radians }
        guard let emitted = lastRingOutputTime else { lastRingOutputTime = time; return [] }
        let elapsed = time-emitted
        guard elapsed >= 1.0/60.0 else { return [] }
        let angularSpeed = abs(ringPending)/elapsed
        let gain = configuration.acceleration ? 0.65+2.35*smoothstep(angularSpeed,0.3,5.0) : 1
        // MultitouchSupport y points upward: clockwise is negative angle; positive scroll is up.
        let requested = -ringPending*0.20*gain
        // Rate limiting must never create extra time budget for a fast first sample.
        // Cap accumulated idle time too, so a stationary touch cannot bank a large jump.
        let limit = configuration.maximumScrollSpeed*min(elapsed,1.0/30.0)
        let output = min(limit,max(-limit,requested))
        guard abs(output) > 0.0001 else { return [] }
        ringPending = 0; lastRingOutputTime = time
        return [.motion(Delta(x:0,y:output),.scroll)]
    }
    private func valid(_ value:Configuration) -> Bool {
        value.maximumPointerSpeed.isFinite && value.maximumScrollSpeed.isFinite &&
        value.maximumPointerSpeed > 0 && value.maximumPointerSpeed <= 3 &&
        value.maximumScrollSpeed > 0 && value.maximumScrollSpeed <= 4 &&
        value.ringStartRadius.isFinite && (0.2...0.45).contains(value.ringStartRadius) &&
        value.swipeDistance.isFinite && (0.1...0.5).contains(value.swipeDistance)
    }
    private func validPoint(_ x:Double,_ y:Double) -> Bool {
        x.isFinite && y.isFinite && (-0.1...1.1).contains(x) && (-0.1...1.1).contains(y)
    }
    private func fresh(_ time:Double,now:Double) -> Bool {
        time.isFinite && time >= 0 && now-time >= -0.02 && now-time <= 0.15
    }
    private func smoothstep(_ value:Double,_ low:Double,_ high:Double) -> Double {
        let t = min(1,max(0,(value-low)/(high-low))); return t*t*(3-2*t)
    }

    // v0.9 source compatibility while callers migrate to the event API.
    mutating func receive(_ message:RemoteTouchMessage, now:Double, speed:Double) -> Delta? {
        guard now.isFinite, speed.isFinite, (0.5...3).contains(speed) else { reset(); return nil }
        switch message {
        case .ready, .cancel: reset(); return nil
        case .reset(let time):
            guard fresh(time,now:now) else { reset(); return nil }
            legacyLast = nil; legacyWaitingForLift = false; return nil
        case let .contact(time,path,phase,x,y):
            guard fresh(time,now:now), validPoint(x,y), (0...7).contains(phase) else { reset(); return nil }
            guard phase == 3 || phase == 4 else { legacyLast = nil; legacyWaitingForLift = false; return nil }
            if phase == 3 { legacyWaitingForLift = false; legacyLast = Contact(time:time,path:path,x:x,y:y); return nil }
            guard !legacyWaitingForLift else { return nil }
            if let previous = legacyLast, time <= previous.time { reset(); return nil }
            defer { legacyLast = Contact(time:time,path:path,x:x,y:y) }
            guard let previous = legacyLast, previous.path == path, time-previous.time < 0.15 else { return nil }
            let dx=x-previous.x, dy=y-previous.y
            guard abs(dx) <= 0.2, abs(dy) <= 0.2 else { return nil }
            return Delta(x:dx*speed,y:dy*speed)
        }
    }
}
