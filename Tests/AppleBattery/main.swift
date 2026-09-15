import Foundation
func fixture(_ groups:[[String:Any]], connected:Bool = true) throws -> Data {
    try JSONSerialization.data(withJSONObject:["SPBluetoothDataType":[[connected ? "device_connected" : "device_not_connected":groups]]])
}
let target = "AA:BB:CC:DD:EE:FF"
func device(_ address:String = target, _ percent:String = "86%") -> [String:Any] {
    ["Renamed Remote":["device_address":address,"device_batteryLevelMain":percent]]
}
func check(_ yes:Bool) { precondition(yes) }
check(AppleBatteryMetadata.percent(try fixture([device()]),for:target) == 86)
check(AppleBatteryMetadata.percent(try fixture([device("aa-bb-cc-dd-ee-ff")]),for:target) == 86)
check(AppleBatteryMetadata.percent(try fixture([device(target,"0%")]),for:target) == 0)
check(AppleBatteryMetadata.percent(try fixture([device(target,"100%")]),for:target) == 100)
check(AppleBatteryMetadata.percent(try fixture([device(target,"101%")]),for:target) == nil)
check(AppleBatteryMetadata.percent(try fixture([device(target,"-1%")]),for:target) == nil)
check(AppleBatteryMetadata.percent(try fixture([device(target,"unknown")]),for:target) == nil)
check(AppleBatteryMetadata.percent(try fixture([device("11:22:33:44:55:66")]),for:target) == nil)
check(AppleBatteryMetadata.percent(try fixture([device(),device(target,"50%")]),for:target) == nil)
check(AppleBatteryMetadata.percent(try fixture([device()],connected:false),for:target) == nil)
check(AppleBatteryMetadata.percent(Data("invalid".utf8),for:target) == nil)
check(AppleBatteryMetadata.percent(try fixture([device()]),for:"invalid") == nil)
check(AppleBatteryMetadata.percent(Data(repeating:32,count:1_048_577),for:target) == nil)
print("PASS: 13 Apple battery metadata checks (exact address, connected-only, range, missing, duplicate, malformed and size bounds)")
