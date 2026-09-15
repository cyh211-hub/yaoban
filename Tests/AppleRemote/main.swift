import Foundation

var checks = 0
func check(_ ok: @autoclosure () -> Bool, _ title: String) {
    precondition(ok(), title); checks += 1
}
check(AppleButtonInput.matches(vendor:0x4C,product:0x315,transport:"Bluetooth Low Energy"),"exact Gen-3 match")
for (v,p,t) in [(0x05AC,0x315,"Bluetooth"),(0x4C,0x266,"Bluetooth"),(0x4C,0x315,"USB"),(0x2717,0x32B8,"Bluetooth Low Energy")] {
    check(!AppleButtonInput.matches(vendor:v,product:p,transport:t),"other device/generation/transport is excluded")
}
check(!AppleButtonInput.matches(vendor:0x4C,product:0x315,transport:nil),"missing identity isn't guessed")
let events: [(UInt32,UInt32,AppleRemoteButton)] = [
    (1,0x86,.back),(12,0x30,.power),(12,0x42,.up),(12,0x43,.down),(12,0x44,.left),(12,0x45,.right),
    (12,0x80,.center),(12,0x60,.tv),(12,4,.siri),(12,0xCD,.playPause),(12,0xE2,.mute),(12,0xE9,.volumeUp),(12,0xEA,.volumeDown)]
check(Set(events.map { $0.2 }) == Set(AppleRemoteButton.allCases),"13 distinct semantic buttons")
for (page,usage,button) in events {
    var state = AppleButtonState()
    check(state.receive(interface:1,cookie:1,page:page,usage:usage,value:1) == [.init(button:button,pressed:true)],"one press")
    check(state.receive(interface:1,cookie:1,page:page,usage:usage,value:1).isEmpty,"held repeats aren't duplicate presses")
    check(state.receive(interface:2,cookie:7,page:page,usage:usage,value:1).isEmpty,"mirrored interface doesn't double-fire")
    check(state.receive(interface:1,cookie:1,page:page,usage:usage,value:0).isEmpty,"mirrored interface still held")
    check(state.receive(interface:2,cookie:7,page:page,usage:usage,value:0) == [.init(button:button,pressed:false)],"last interface releases once")
    check(state.receive(interface:2,cookie:7,page:page,usage:usage,value:0).isEmpty,"duplicate release ignored")
}
var a = AppleButtonState(), b = AppleButtonState()
_ = a.receive(interface:1,cookie:2,page:12,usage:4,value:1)
_ = b.receive(interface:2,cookie:2,page:12,usage:4,value:1)
check(a.reset() == [.init(button:.siri,pressed:false)] && b.buttons == [.siri],"reset never releases another remote")
check(b.remove(interface:99).isEmpty && b.buttons == [.siri],"unrelated disconnect ignored")
check(b.remove(interface:2) == [.init(button:.siri,pressed:false)] && b.buttons.isEmpty,"disconnect clears held input")
for (p,u,v) in [(UInt32(0xFF00),UInt32(4),1),(13,0x30,1),(6,0x20,1),(12,4,99),(12,4,-1),(12,0x1234,0)] {
    check(AppleButtonInput.decode(page:p,usage:u,value:v) == nil,"vendor/audio/coordinate/invalid inputs never become Siri")
}
check(AppleButtonInput.battery(0) == 0 && AppleButtonInput.battery(100) == 100,"battery endpoints are real readings")
check(AppleButtonInput.battery(nil) == nil && AppleButtonInput.battery(-1) == nil && AppleButtonInput.battery(255) == nil,"unknown battery isn't guessed")
struct CapturedEvent: Decodable {
    let at: Double, interface: UInt64, cookie: UInt32, page: UInt32, usage: UInt32, reportID: UInt32, value: Int
    let expectedButton: AppleRemoteButton
}
struct Capture: Decodable { let vendorID: Int, productID: Int, events: [CapturedEvent] }
let fixture = try JSONDecoder().decode(Capture.self,from:Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/apple-a2854-buttons-v1.json")))
var captured = AppleButtonState()
check(fixture.vendorID == 0x4C && fixture.productID == 0x315 && fixture.events.count == 24,"fixture is the 12 tested physical keys")
for event in fixture.events {
    check(event.reportID == 0xFB,"actual button report identity")
    check(captured.receive(interface:event.interface,cookie:event.cookie,page:event.page,usage:event.usage,value:event.value) == [.init(button:event.expectedButton,pressed:event.value == 1)],"captured hardware event preserves exact down/up")
}
check(captured.buttons.isEmpty,"real session ends with no held keys")
let siri = fixture.events.filter { $0.expectedButton == .siri }
check(siri.count == 2 && siri[1].at - siri[0].at > 1.4,"real side-button hold preserves duration")
var connection = AppleHIDConnectionPolicy()
check(connection.needsRebuild(liveInterfaces:[]),"empty startup establishes no connection")
check(!connection.needsRebuild(liveInterfaces:[]),"empty polling does not reconnect or pair")
check(connection.needsRebuild(liveInterfaces:[1,2,3]),"new physical interface group is acquired")
for _ in 0..<30 { check(!connection.needsRebuild(liveInterfaces:[1,2,3]),"failed or ready acquisition never repeats on unchanged inventory") }
check(connection.needsRebuild(liveInterfaces:[]),"actual disconnect invalidates successful or failed acquisition")
check(connection.needsRebuild(liveInterfaces:[4,5,6]),"fresh reconnect retries after an earlier failure")
check(connection.needsRebuild(liveInterfaces:[4,6]),"partial removal rebuilds remaining sibling interfaces")
check(!connection.needsRebuild(liveInterfaces:[4,6]),"remaining group is not repeatedly reopened")
check(connection.needsRebuild(liveInterfaces:[4,6,7]),"replacement sibling is included even if the button interface survives")
connection.reset()
check(connection.needsRebuild(liveInterfaces:[4,6,7]),"explicit restart permits retry without a new pairing")
check(connection.needsRebuild(liveInterfaces:[4,6,7],systemConnected:false),"manual Bluetooth disconnect cancels input even when HID interfaces remain cached")
check(!connection.needsRebuild(liveInterfaces:[4,6,7],systemConnected:false),"cached HID cannot cause repeated acquisition while Bluetooth is disconnected")
check(connection.needsRebuild(liveInterfaces:[4,6,7],systemConnected:true),"Bluetooth reconnect rearms the same cached HID IDs after canceling old held state")
check(RemoteBluetoothDevice.validAddress("AA:12:34:56:78:90") && RemoteBluetoothDevice.validAddress("aa-12-34-56-78-90"),"supported system address formats")
for value in ["", "AA:12:34", "AA:12:34:56:78:GG", "AA:12:34:56:78:90:11", " AA:12:34:56:78:90"] {
    check(!RemoteBluetoothDevice.validAddress(value),"invalid parent address cannot associate a Bluetooth device")
}
check(RemoteBluetoothDevice.displayName("  AppleTV遥控器\n") == "AppleTV遥控器","system alias displayed as literal text without controls")
check(RemoteBluetoothDevice.displayName(nil) == nil && RemoteBluetoothDevice.displayName(" \n") == nil,"missing alias preserves previous device name")
check(RemoteBluetoothDevice.displayName(String(repeating:"名",count:100))?.count == 80,"alias stays within saved-name validation bounds")
print("PASS: \(checks) Apple input checks — filtering, button edges, duplicates, per-remote ownership, disconnect, unknown reports, battery, interface acquisition recovery")
