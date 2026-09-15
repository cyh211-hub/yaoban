import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}
func point(_ time: Double, _ phase: Int, _ x: Double = 0.5, _ y: Double = 0.5,
           path: Int32 = 1) -> RemoteTouchMessage {
    .contact(time:time,path:path,phase:phase,x:x,y:y)
}
func receive(_ recognizer: inout RemoteTouchTap, _ message: RemoteTouchMessage,
             _ now: Double, maximum: Int = 3, interval: Double = 0.3) -> [Int] {
    recognizer.receive(message,now:now,maxTapCount:maximum,interval:interval)
}
func tap(_ recognizer: inout RemoteTouchTap, _ time: Double, maximum: Int = 3,
         path: Int32 = 1) -> [Int] {
    check(receive(&recognizer,point(time,3,path:path),time,maximum:maximum).isEmpty,"tap began with output")
    return receive(&recognizer,.reset(time+0.04),time+0.04,maximum:maximum)
}
func rejects(_ settings: RemoteTouchSettings, _ message: String) {
    do { _ = try settings.validated(); fatalError(message) } catch { checks += 1 }
}

// Settings remain compatible with files created before gestures existed.
let legacy = Data(#"{"mode":"pointer","speed":1.7,"acceleration":false}"#.utf8)
let old = try JSONDecoder().decode(RemoteTouchSettings.self,from:legacy)
check(old.gestureBindings == RemoteTouchSettings.defaultGestureBindings,"legacy settings did not gain inert tap defaults")
check(old.binding(for:.swipeUp) == nil,"legacy swipe must use directional fallback")
check(old.maximumConfiguredTapCount == 0,"inert tap defaults enabled recognition")
check(old.tapInterval == 0.3 && old.ringStartRadius == 0.35 && old.swipeDistance == 0.17,"legacy thresholds changed")

var settings = old
settings.setBinding([4,0xE0,4],for:.tap2)
settings.setBinding([0x4F],for:.swipeRight)
check(settings.binding(for:.tap2) == [0xE0,4],"setter did not normalize a gesture chord")
check(settings.maximumConfiguredTapCount == 2,"maximum configured tap count is wrong")
let encoded = try JSONEncoder().encode(settings)
let json = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
let stored = json["gestureBindings"] as? [String:Any]
check(stored?["tap2"] != nil && stored?["swipeRight"] != nil,"gesture keys were not persisted as raw strings")
let roundTrip = try JSONDecoder().decode(RemoteTouchSettings.self,from:encoded)
check(roundTrip == settings,"gesture settings did not round-trip")
settings.setBinding(nil,for:.swipeRight)
check(settings.binding(for:.swipeRight) == nil,"nil did not restore legacy swipe fallback")

var unnormalized = settings
unnormalized.gestureBindings[.tap3] = [5,0xE1,5]
let normalized = try unnormalized.validated()
check(normalized.binding(for:.tap3) == [0xE1,5],"validation did not normalize gesture keys")
var invalid = settings; invalid.tapInterval = 0.19; rejects(invalid,"short tap interval accepted")
invalid = settings; invalid.tapInterval = 0.61; rejects(invalid,"long tap interval accepted")
invalid = settings; invalid.ringStartRadius = 0.46; rejects(invalid,"large ring radius accepted")
invalid = settings; invalid.swipeDistance = 0.09; rejects(invalid,"short swipe accepted")
invalid = settings; invalid.gestureBindings[.tap1] = Array(repeating:4,count:10); rejects(invalid,"oversized chord accepted")
invalid = settings; invalid.gestureBindings[.tap1] = [0xFFFF]; rejects(invalid,"unknown keyboard key accepted")
do {
    _ = try JSONDecoder().decode(RemoteTouchSettings.self,from:Data(#"{"gestureBindings":{"tap4":[]}}"#.utf8))
    fatalError("unknown gesture decoded")
} catch { checks += 1 }

// A triple-capable setup emits only the triple for three rapid taps.
var recognizer = RemoteTouchTap(), output: [Int] = []
output += tap(&recognizer,1.00)
output += tap(&recognizer,1.10,path:2)
output += tap(&recognizer,1.20,path:3)
check(output == [3],"rapid triple emitted an intermediate tap")
check(recognizer.tick(now:2).isEmpty,"triple remained pending")

recognizer.reset()
check(tap(&recognizer,2.00).isEmpty,"single emitted before its deadline")
check(recognizer.tick(now:2.339).isEmpty,"single emitted early")
check(recognizer.tick(now:2.34) == [1],"single did not resolve at its deadline")
check(recognizer.tick(now:2.5).isEmpty,"single emitted twice")

recognizer.reset(); output = []
output += tap(&recognizer,3.00,maximum:2)
check(recognizer.resolutionDeadline == 3.34,"pending double did not expose its resolution deadline")
check(receive(&recognizer,point(3.08,2),3.08,maximum:2).isEmpty,"hover emitted between taps")
output += tap(&recognizer,3.15,maximum:2,path:2)
check(output == [2],"double did not resolve immediately at configured maximum")

// Movement, long contact, path changes and multiple contacts never become taps.
recognizer.reset()
check(receive(&recognizer,point(4,3),4).isEmpty,"drag began with output")
check(receive(&recognizer,point(4.04,4,0.62),4.04).isEmpty,"drag emitted a tap")
check(receive(&recognizer,.reset(4.05),4.05).isEmpty,"drag lift emitted a tap")
check(recognizer.tick(now:5).isEmpty,"drag left a pending tap")

recognizer.reset()
_ = receive(&recognizer,point(5,3),5)
check(receive(&recognizer,point(5.31,4),5.31).isEmpty,"held contact emitted")
check(receive(&recognizer,.reset(5.32),5.32).isEmpty && recognizer.tick(now:6).isEmpty,"held contact became a tap")

recognizer.reset()
_ = receive(&recognizer,point(6,3),6)
check(receive(&recognizer,point(6.03,5,path:2),6.03).isEmpty,"wrong path lift emitted")
check(recognizer.tick(now:7).isEmpty,"wrong path lift left output")

recognizer.reset()
_ = receive(&recognizer,point(7,3),7)
check(receive(&recognizer,.cancel(7.02),7.02).isEmpty,"multi-contact cancel emitted")
check(recognizer.tick(now:8).isEmpty,"multi-contact cancel left output")

// External reset/disconnect and stream READY cancel unresolved taps.
recognizer.reset(); _ = tap(&recognizer,8.00)
recognizer.reset()
check(recognizer.tick(now:9).isEmpty,"external reset executed a pending tap")
_ = tap(&recognizer,9.00)
check(receive(&recognizer,.ready,9.05).isEmpty && recognizer.tick(now:10).isEmpty,"stream restart executed a pending tap")

// No configured tap action means no recognition or delay state.
recognizer.reset()
check(receive(&recognizer,point(10,3),10,maximum:0).isEmpty,"disabled recognizer began output")
check(receive(&recognizer,.reset(10.04),10.04,maximum:0).isEmpty,"disabled recognizer tapped")
check(recognizer.tick(now:11).isEmpty,"disabled recognizer retained state")

// Malformed direct inputs fail closed and clear an earlier pending tap.
recognizer.reset(); _ = tap(&recognizer,11.00)
check(receive(&recognizer,point(10.9,3),11.05).isEmpty,"backward stream time emitted")
check(recognizer.tick(now:12).isEmpty,"bad time retained pending output")
_ = receive(&recognizer,point(12,3),12)
check(receive(&recognizer,point(12.01,4,Double.nan),12.01).isEmpty,"NaN point emitted")
check(recognizer.tick(now:13).isEmpty,"bad point retained state")
check(receive(&recognizer,point(13,3),13,maximum:4).isEmpty,"invalid maximum emitted")
check(receive(&recognizer,point(13.1,3),13.1,interval:0.1).isEmpty,"invalid interval emitted")

// Explicit break-touch is also a valid lift and is not repeated by the R frame.
recognizer.reset()
_ = receive(&recognizer,point(14,3),14,maximum:1)
check(receive(&recognizer,point(14.04,5),14.04,maximum:1) == [1],"break-touch did not finalize")
check(receive(&recognizer,.reset(14.05),14.05,maximum:1).isEmpty,"R repeated a break-touch tap")

print("PASS: \(checks) touch gesture settings/tap checks; no device, timer, or system input used")
