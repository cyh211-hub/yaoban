import Foundation

var checks = 0
func check(_ condition:Bool,_ message:String) { checks += 1; if !condition { fatalError(message) } }
func sample(_ time:Double,_ phase:Int,_ x:Double = 0.4,_ y:Double = 0.4,_ path:Int32 = 1) -> RemoteTouchMessage {
    .contact(time:time,path:path,phase:phase,x:x,y:y)
}
var motion = RemoteTouchMotion()
check(motion.receive(sample(10,4),now:10,speed:1) == nil,"held contact on startup is ignored")
check(motion.receive(sample(10.01,4,0.5),now:10.01,speed:1) == nil,"startup cannot drift before lift")
check(motion.receive(sample(10.02,5),now:10.02,speed:1) == nil,"lift never moves pointer")
check(motion.receive(sample(10.03,3),now:10.03,speed:1) == nil,"new contact anchors without jump")
let movement = motion.receive(sample(10.04,4,0.5,0.3),now:10.04,speed:2)!
check(abs(movement.x - 0.2) < 0.0001 && abs(movement.y + 0.2) < 0.0001,"coordinates and speed preserve directions")
for phase in [0,1,2,5,6,7] {
    check(motion.receive(sample(10.05,phase,0.9),now:10.05,speed:1) == nil,"hover and lift phases cannot move pointer")
}
motion.reset()
_ = motion.receive(sample(20,3),now:20,speed:1)
check(motion.receive(sample(20.01,4,0.5,0.5,2),now:20.01,speed:1) == nil,"changing finger identity reanchors")
check(motion.receive(sample(21,4,0.6,0.5,2),now:21,speed:1) == nil,"gap cannot bridge old contact")
check(motion.receive(sample(21.01,4,1.1,0.5,2),now:21.01,speed:1) == nil,"large coordinate jump is rejected")
check(motion.receive(sample(21.02,4,0.5),now:22,speed:1) == nil,"queued stale frame cannot move pointer")
check(motion.receive(sample(22.01,4,0.6),now:22.01,speed:1) == nil,"stale frame requires a new contact cycle")
for invalid in [Double.nan, .infinity, -1, 4] {
    check(motion.receive(sample(23,3),now:23,speed:invalid) == nil,"invalid speed does not output")
}
check(RemoteTouchMessage.parse("READY") == .ready,"ready protocol")
check(RemoteTouchMessage.parse("R 12.0") == .reset(12),"no-contact protocol")
check(RemoteTouchMessage.parse("T 12.0 1 4 0.4 0.5") == sample(12,4,0.4,0.5),"contact protocol")
for line in ["", "READY extra", "T nan 1 4 0.4 0.5", "R inf", "R -1", "T 12 1 8 0 0", "T 12 1 4 1.2 0", "T 12 1 4 nan 0", "T 12 99999999999999 4 0 0", "T 12 1 4 0 0 extra", "T  12 1 4 0 0", String(repeating:"x",count:201)] {
    check(RemoteTouchMessage.parse(line) == nil,"reject malformed \(line.prefix(40))")
}
// Timestamps may repeat or go backwards after a restart; never bridge that interval.
motion.reset(); _ = motion.receive(sample(30,3),now:30,speed:1)
check(motion.receive(sample(29.99,4,0.5),now:30,speed:1) == nil,"old timestamp ignored")
motion.reset(); _ = motion.receive(.reset(40),now:40,speed:1)
check(motion.receive(sample(40.01,4),now:40.01,speed:1) == nil,"empty frame permits a fresh anchor")
check(motion.receive(sample(40.02,4,0.45),now:40.02,speed:1) != nil,"motion resumes after no-contact frame")
print("PASS: \(checks) touch protocol/motion checks; no system input posted")
