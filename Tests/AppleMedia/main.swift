import Foundation
func require(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
var checks = 0
for key in AppleMediaKey.allCases {
    var policy = AppleMediaPolicy(); policy.owned = [key]
    require(policy.suppress(key,down:true,repeating:false,time:1,origin:.selected,synthetic:false),"exact selected source suppressed"); checks += 1
    require(!policy.suppress(key,down:true,repeating:false,time:1.01,origin:.other,synthetic:false),"different sender always passes during owned press"); checks += 1
    require(!policy.suppress(key,down:true,repeating:false,time:1.01,origin:.selected,synthetic:true),"synthetic output passes"); checks += 1
    policy.reset()
    require(!policy.suppress(key,down:false,repeating:false,time:1.1,origin:.selected,synthetic:false),"release of a press that preceded the tap must pass"); checks += 1
    require(!policy.suppress(key,down:true,repeating:true,time:1.2,origin:.selected,synthetic:false),"repeat of a press that preceded the tap must pass"); checks += 1
    policy.note(key,down:false,time:1.3)
    require(!policy.suppress(key,down:false,repeating:false,time:1.31,origin:.unknown,synthetic:false),"physical release alone cannot authorize suppression"); checks += 1
    require(!policy.suppress(key,down:true,repeating:false,time:2,origin:.unknown,synthetic:false),"no evidence passes"); checks += 1
    policy.note(key,down:true,time:3)
    require(!policy.suppress(key,down:true,repeating:false,time:3.09,origin:.unknown,synthetic:false),"outside attribution window passes"); checks += 1
    policy.note(key,down:true,time:4)
    require(policy.suppress(key,down:true,repeating:false,time:4.02,origin:.unknown,synthetic:false),"matching physical edge suppresses native down"); checks += 1
    require(!policy.suppress(key,down:true,repeating:false,time:4.03,origin:.unknown,synthetic:false),"single-use token does not suppress another ordinary press"); checks += 1
    require(policy.suppress(key,down:true,repeating:true,time:4.6,origin:.unknown,synthetic:false),"matched gesture suppresses native repeat"); checks += 1
    policy.note(key,down:false,time:5)
    require(policy.suppress(key,down:false,repeating:false,time:5.03,origin:.unknown,synthetic:false),"native release suppressed with gesture"); checks += 1
    policy.reset()
    require(!policy.suppress(key,down:true,repeating:true,time:5.04,origin:.unknown,synthetic:false),"disconnect/reset releases suppression"); checks += 1
    policy.note(key,down:true,time:6)
    _ = policy.suppress(key,down:true,repeating:false,time:6.01,origin:.unknown,synthetic:false)
    policy.note(key,down:false,time:7)
    require(!policy.suppress(key,down:true,repeating:true,time:7.11,origin:.unknown,synthetic:false),"missing native release expires after physical release"); checks += 1
    policy.reset(); policy.owned = []
    require(!policy.suppress(key,down:true,repeating:false,time:8,origin:.selected,synthetic:false),"unowned source passes"); checks += 1
}
var mixed = AppleMediaPolicy(); mixed.owned = Set(AppleMediaKey.allCases)
mixed.note(.volumeUp,down:true,time:10)
require(!mixed.suppress(.mute,down:true,repeating:false,time:10.01,origin:.unknown,synthetic:false),"different media code passes")
require(!mixed.suppress(.volumeUp,down:true,repeating:false,time:.nan,origin:.selected,synthetic:false),"invalid time passes")
require(AppleMediaKey(button:.power) == nil && AppleMediaKey(rawValue:6) == nil,"power and other system events excluded")
print("PASS: \(checks+3) media suppression policy checks; no system inputs")

// Recorded cghid/session timestamps from the same four physical remote presses.
// The legacy conversion produced ~685s while HID used ~28,552s: no edge could match.
let tickScale = (125.0 / 3.0) / 1e9
let samples: [(AppleMediaKey,UInt64,UInt64)] = [
    (.volumeUp,685259774723,28552492132833),
    (.volumeDown,685535535212,28563984002791),
    (.mute,685646058796,28568587342958),
    (.playPause,685723466545,28571811642791)
]
for (key,raw,session) in samples {
    let physicalTime = Double(raw)*tickScale
    let now = Double(session)/1e9
    let fixed = AppleMediaClock.normalize(raw,ticksToSeconds:tickScale,now:now)!
    require(fixed.rawTicks && abs(fixed.seconds-physicalTime)<0.000001,"raw HID-stage ticks normalize to HID time")
    var old = AppleMediaPolicy(); old.owned = [key]; old.note(key,down:true,time:physicalTime)
    require(!old.suppress(key,down:true,repeating:false,time:Double(raw)/1e9,origin:.unknown,synthetic:false),"recorded regression: old clock misses actual physical press")
    require(old.suppress(key,down:true,repeating:false,time:fixed.seconds,origin:.unknown,synthetic:false),"fixed clock suppresses paired physical press")
    require(!old.suppress(key,down:true,repeating:false,time:fixed.seconds,origin:.other,synthetic:false),"other devices still pass")
    let converted = AppleMediaClock.normalize(session,ticksToSeconds:tickScale,now:now)!
    require(!converted.rawTicks && converted.seconds == now,"already normalized nanoseconds remain supported")
}
require(AppleMediaClock.normalize(1_000_000_000,ticksToSeconds:1e-9,now:1)!.seconds == 1,"Intel 1ns ticks unchanged")
require(AppleMediaClock.normalize(0,ticksToSeconds:tickScale,now:1) == nil,"zero timestamp ignored")
require(AppleMediaClock.normalize(123,ticksToSeconds:tickScale,now:100) == nil,"stale or invalid clock ignored")
require(AppleMediaClock.normalize(123,ticksToSeconds:.nan,now:1) == nil,"invalid timebase ignored")
require(AppleMediaClock.normalize(123,ticksToSeconds:tickScale,now:.nan) == nil,"invalid now ignored")
print("PASS: 25 clock regression checks, four recorded media timestamps, nanosecond fallback and invalid-clock rejection")
