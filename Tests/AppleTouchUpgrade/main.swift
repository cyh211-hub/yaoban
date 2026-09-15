import Foundation

var checks = 0
func check(_ value:@autoclosure () -> Bool,_ message:String) {
    checks += 1
    if !value() { fatalError(message) }
}
func point(_ time:Double,_ phase:Int,_ x:Double,_ y:Double,_ path:Int32 = 7) -> RemoteTouchMessage {
    .contact(time:time,path:path,phase:phase,x:x,y:y)
}
func xy(angle:Double,radius:Double = 0.44) -> (Double,Double) {
    (0.5+cos(angle)*radius,0.5+sin(angle)*radius)
}

let fast = RemoteTouchMotion.Configuration(mode:.pointer,maximumPointerSpeed:0.5,maximumScrollSpeed:0.7,acceleration:true)
var motion = RemoteTouchMotion()
_ = motion.receive(point(1,.init(3),0.3,0.3),now:1,configuration:fast)
let capped = motion.receive(point(1.01,4,0.45,0.3),now:1.01,configuration:fast)
guard case .motion(let capDelta,.pointer)? = capped.first else { fatalError("pointer event missing") }
check(hypot(capDelta.x,capDelta.y) <= 0.0050001,"acceleration exceeded configured pointer speed ceiling")
check(hypot(capDelta.x,capDelta.y) > 0,"valid movement was lost")
check(motion.receive(point(1.30,4,0.46,0.3),now:1.30,configuration:fast).isEmpty,"large timestamp gap was bridged")
check(motion.receive(point(1.31,4,0.47,0.3),now:1.31,configuration:fast).isEmpty,"motion resumed before a new gesture")

let hybrid = RemoteTouchMotion.Configuration(mode:.hybrid,maximumPointerSpeed:1,maximumScrollSpeed:0.6,acceleration:true)
motion.reset()
var t = 2.0
var p = xy(angle:-2.85)
_ = motion.receive(point(t,3,p.0,p.1),now:t,configuration:hybrid)
var ringEvents:[RemoteTouchMotion.Event] = []
// Clockwise rotation crosses -pi/+pi; MultitouchSupport y increases upward.
for angle in [-3.00,-3.14,3.00,2.85,2.70] {
    t += 0.02; p = xy(angle:angle)
    ringEvents += motion.receive(point(t,4,p.0,p.1),now:t,configuration:hybrid)
}
let ringDeltas = ringEvents.compactMap { event -> RemoteTouchMotion.Delta? in
    if case .motion(let delta,.scroll) = event { return delta }; return nil
}
check(!ringDeltas.isEmpty,"clockwise ring did not start after threshold")
check(ringDeltas.allSatisfy { $0.y > 0 && $0.x == 0 },"clockwise ring must scroll up")
check(ringDeltas.allSatisfy { abs($0.y) <= 0.0200001 },"accelerated ring exceeded scroll speed ceiling")
check(motion.receive(.reset(t+0.01),now:t+0.01,configuration:hybrid).isEmpty,"release emitted output")
check(motion.receive(point(t+0.02,4,p.0,p.1),now:t+0.02,configuration:hybrid).isEmpty,"release did not stop the gesture")

motion.reset(); t = 2.5; p = xy(angle:2.85)
_ = motion.receive(point(t,3,p.0,p.1),now:t,configuration:hybrid)
var counterclockwise:[RemoteTouchMotion.Event] = []
for angle in [3.00,3.14,-3.00,-2.85,-2.70] {
    t += 0.02; p = xy(angle:angle)
    counterclockwise += motion.receive(point(t,4,p.0,p.1),now:t,configuration:hybrid)
}
check(counterclockwise.allSatisfy { event in
    if case .motion(let delta,.scroll) = event { return delta.y < 0 }; return false
} && !counterclockwise.isEmpty,"counterclockwise ring must scroll down across pi")

motion.reset(); t = 3
_ = motion.receive(point(t,3,0.60,0.50),now:t,configuration:hybrid)
let inner1 = motion.receive(point(t+0.02,4,0.70,0.50),now:t+0.02,configuration:hybrid)
let inner2 = motion.receive(point(t+0.04,4,0.86,0.50),now:t+0.04,configuration:hybrid)
check((inner1+inner2).allSatisfy { if case .motion(_,.pointer) = $0 { return true }; return false },"inner landing changed to ring after moving outward")

let swipe = RemoteTouchMotion.Configuration(mode:.swipe,maximumPointerSpeed:1,maximumScrollSpeed:1,acceleration:false)
motion.reset(); t = 4
_ = motion.receive(point(t,3,0.25,0.5),now:t,configuration:swipe)
let firstSwipe = motion.receive(point(t+0.04,4,0.44,0.5),now:t+0.04,configuration:swipe)
let secondSwipe = motion.receive(point(t+0.08,4,0.60,0.5),now:t+0.08,configuration:swipe)
check(firstSwipe == [.swipe(.right)],"right swipe was not classified")
check(secondSwipe.isEmpty,"one gesture emitted more than one swipe")

// Independent time-budget oracle: output intervals are measured from DOWN,
// not from the preceding sample; sample cadence must not create speed budget.
for acceleration in [false,true] {
    for sign in [-1.0,1.0] {
        for cadence in [1.0/120,1.0/240] {
            let configuration = RemoteTouchMotion.Configuration(mode:.hybrid,maximumPointerSpeed:1,maximumScrollSpeed:0.6,acceleration:acceleration)
            var tracker = RemoteTouchMotion(), time = 10.0, lastOutput = 10.0, total = 0.0
            var angle = 0.0, outputs = 0
            var p = xy(angle:angle)
            _ = tracker.receive(point(time,3,p.0,p.1),now:time,configuration:configuration)
            for index in 0..<160 {
                time += cadence * (index % 3 == 0 ? 1 : index % 3 == 1 ? 0.8 : 1.2)
                angle += sign * 0.34; p = xy(angle:angle)
                for event in tracker.receive(point(time,4,p.0,p.1),now:time,configuration:configuration) {
                    guard case .motion(let delta,.scroll) = event else { fatalError("ring emitted pointer") }
                    outputs += 1; total += abs(delta.y)
                    check(delta.y * sign < 0,"high frequency rotation direction changed")
                    check(abs(delta.y) <= 0.6*(time-lastOutput)+1e-9,"ring emission exceeded elapsed speed budget")
                    check(total <= 0.6*(time-10)+1e-9,"ring cumulative output exceeded speed cap")
                    lastOutput = time
                }
            }
            check(outputs > 0,"high frequency ring produced no output")
        }
    }
}

// A MOVE without a witnessed DOWN must never invent a landing region.
motion.reset(); t = 50
_ = motion.receive(.reset(t),now:t,configuration:hybrid)
for index in 1...12 {
    let time = t+Double(index)*0.01, p = xy(angle:Double(index)*0.12)
    check(motion.receive(point(time,4,p.0,p.1),now:time,configuration:hybrid).isEmpty,"MOVE-only stream invented outer landing")
}
motion.reset(); t = 51
_ = motion.receive(point(t,3,0.5,0.5),now:t,configuration:hybrid)
_ = motion.receive(point(t+0.01,3,0.9,0.5),now:t+0.01,configuration:hybrid)
check(motion.receive(point(t+0.02,4,0.89,0.6),now:t+0.02,configuration:hybrid).isEmpty,"second DOWN switched region without lift")
motion.reset(); t = 52
_ = motion.receive(point(t,3,0.5,0.5),now:t,configuration:hybrid)
_ = motion.receive(point(t-0.01,3,0.9,0.5),now:t,configuration:hybrid)
check(motion.receive(point(t+0.02,4,0.89,0.6),now:t+0.02,configuration:hybrid).isEmpty,"out-of-order DOWN restarted gesture")

print("PASS: \(checks) upgraded touch motion checks; no device or system input used")
