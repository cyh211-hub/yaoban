import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message:String) { checks += 1; if !condition() { fatalError(message) } }
func stamp(_ time:Double) -> String { String(format:"%.6f",time) }
func pending(_ controller:AppleTouchController) {
    let now = ProcessInfo.processInfo.systemUptime
    controller.testInput("T \(stamp(now-0.02)) 1 3 0.5 0.5\nT \(stamp(now-0.01)) 1 7 0.5 0.5\n")
}
func configured() -> AppleTouchController {
    let controller = AppleTouchController()
    controller.testSettings(RemoteTouchSettings(mode:.hybrid,gestureBindings:[.tap1:[4],.tap2:[5]]))
    controller.testInput("REA"); check(!controller.testReady,"partial READY was accepted")
    controller.testInput("DY\n"); check(controller.testReady,"split READY was not accepted")
    check(controller.status == "等待触控输入","READY incorrectly claimed observed input")
    return controller
}
for boundary in ["EOF","READY","invalid","stop","physical"] {
    let controller = configured(); var taps:[Int] = []; var motionCount = 0
    controller.tap = { taps.append($0) }; controller.event = { _ in motionCount += 1 }
    pending(controller); check(taps.isEmpty,"single resolved before multi-tap interval")
    check(controller.status == "圆盘已就绪","fresh touch did not mark observed input")
    switch boundary {
    case "EOF": controller.testEOF()
    case "READY": controller.testInput("READY\n")
    case "invalid": controller.testInput("unexpected\n")
    case "stop": controller.stop()
    default: controller.notePhysicalKeys([0x28])
    }
    controller.tick(now:ProcessInfo.processInfo.systemUptime+0.4)
    check(taps.isEmpty,"\(boundary) allowed pending tap after cancellation")
    check(motionCount == 0,"tap trace emitted motion")
    controller.stop()
}
let controller = configured(); var received:[Int] = []
controller.tap = { received.append($0) }; pending(controller)
controller.tick(now:ProcessInfo.processInfo.systemUptime+0.31)
check(received.isEmpty,"command skipped physical-button arbitration")
controller.tick(now:ProcessInfo.processInfo.systemUptime+0.40)
check(received == [1],"single deadline did not route exactly once")
controller.tick(now:ProcessInfo.processInfo.systemUptime+0.41)
check(received == [1],"single deadline repeated")
controller.stop()
// A mechanical circular key cancels touch commands whichever channel arrives first.
for physicalFirst in [false,true] {
    let c = configured(); c.testSettings(RemoteTouchSettings(mode:.hybrid,gestureBindings:[.tap1:[4]]))
    var outputs:[Int] = []; c.tap = { outputs.append($0) }
    if physicalFirst { c.notePhysicalKeys([0x28]) }
    pending(c)
    if !physicalFirst { c.notePhysicalKeys([0x28]) }
    c.tick(now:ProcessInfo.processInfo.systemUptime+0.1)
    check(outputs.isEmpty,"circular key and touch both executed")
    c.stop()
}
let side = configured(); var sideTaps:[Int] = []; side.tap = { sideTaps.append($0) }
pending(side); side.notePhysicalKeys([0x80])
side.tick(now:ProcessInfo.processInfo.systemUptime+0.31)
side.tick(now:ProcessInfo.processInfo.systemUptime+0.40)
check(sideTaps == [1],"side key swallowed a completed independent surface tap")
side.stop()
let stale = configured(); var staleTaps:[Int] = []; stale.tap = { staleTaps.append($0) }
pending(stale); stale.tick(now:ProcessInfo.processInfo.systemUptime+5)
stale.tick(now:ProcessInfo.processInfo.systemUptime+5.1)
check(staleTaps.isEmpty,"late main-loop tick replayed an expired tap")
stale.stop()
let queued = configured(); queued.testSettings(RemoteTouchSettings(mode:.hybrid,gestureBindings:[.tap1:[4]]))
var queuedTaps:[Int] = []; queued.tap = { queuedTaps.append($0) }
pending(queued); queued.testEOF(); queued.tick(now:ProcessInfo.processInfo.systemUptime+0.1)
check(queuedTaps.isEmpty,"EOF did not cancel queued arbitration command")
queued.stop()

func swipeTrace(_ c:AppleTouchController) {
    let now = ProcessInfo.processInfo.systemUptime
    c.testInput("T \(stamp(now-0.04)) 1 3 0.3 0.5\nT \(stamp(now-0.03)) 1 4 0.45 0.5\nT \(stamp(now-0.02)) 1 4 0.6 0.5\n")
}
for boundary in ["none","circular","EOF","READY","stale"] {
    let c = configured(); c.testSettings(RemoteTouchSettings(mode:.swipe)); var events:[RemoteTouchMotion.Event] = []
    c.event = { events.append($0) }; swipeTrace(c)
    check(events.isEmpty,"swipe bypassed arbitration")
    switch boundary {
    case "circular": c.notePhysicalKeys([0x4F])
    case "EOF": c.testEOF()
    case "READY": c.testInput("READY\n")
    case "stale": c.testInput("R \(stamp(ProcessInfo.processInfo.systemUptime-1))\n")
    default: break
    }
    c.tick(now:ProcessInfo.processInfo.systemUptime+0.1)
    check(events == (boundary == "none" ? [.swipe(.right)] : []),"swipe arbitration boundary failed: \(boundary)")
    c.stop()
}

print("PASS: \(checks) controller stream/cancellation checks; no device or system input used")
