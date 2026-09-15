// Exercise the production lifecycle/socket parser against a local fake broker.
// No Bluetooth, HID, CoreAudio, preferences, root service or permission prompts.
import Foundation
import Darwin
struct BoundApple {
    let id = "test"
    let identity = "test"
    let address: String
    static var currentAddress = "AA:BB:CC:DD:EE:FF"
    static var delay: Double = 0
    static func resolve() throws -> BoundApple {
        let duration = delay
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        return BoundApple(address: currentAddress)
    }
}
struct AppleVoiceAddressedCapture {
    enum Event { case reset, report(Data, Bool) }
    var stopped = false
    init?(address: String, startedAt: Double, duration: Double) {}
    mutating func receive(_ line: String, now: Double) -> Event? { .report(Data([1]), true) }
}
final class AppleVoiceDecoder {
    init() throws {}
    func reset() throws {}
    func consume(reportID: UInt8, payload: Data) throws -> [Int16] { [10,20] }
}
func check(_ value: @autoclosure () -> Bool, _ name: String) { precondition(value(), name) }
func spin(_ condition: () -> Bool, timeout: Double = 4) {
    let until = Date().addingTimeInterval(timeout)
    while !condition() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(condition(), "asynchronous condition timed out")
}
let path = "/private/tmp/yb-voice-\(UUID().uuidString.prefix(8)).sock"
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let bytes = Array(path.utf8CString).map { UInt8(bitPattern: $0) }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
check(bound == 0 && listen(listener, 4) == 0, "fake broker listening")
defer { close(listener); unlink(path) }
let stateLock = NSLock()
var requests = 0, closures = 0, delayed = false, corrupt = false
func sendFrame(_ fd: Int32, _ kind: UInt8, _ payload: Data = Data()) {
    let n = payload.count
    let message = Data([kind, UInt8((n>>24)&255), UInt8((n>>16)&255), UInt8((n>>8)&255), UInt8(n&255)]) + payload
    _ = message.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
}
DispatchQueue.global().async {
    while true {
        let fd = accept(listener,nil,nil); if fd < 0 { return }
        var yes: Int32 = 1; _ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,4)
        var request = Data(), byte: UInt8 = 0
        while Darwin.read(fd,&byte,1) == 1 && byte != 10 && request.count < 16 { request.append(byte) }
        guard !request.isEmpty else { close(fd); continue }
        stateLock.lock(); requests += 1; let wait = delayed; let bad = corrupt; stateLock.unlock()
        let warm = String(data:request,encoding:.utf8) == "WARM"
        if !warm {
            if wait { Thread.sleep(forTimeInterval:0.3) }
            if bad { sendFrame(fd,7) }
            else { sendFrame(fd,1); sendFrame(fd,2,Data("synthetic\n".utf8)) }
            _ = Darwin.read(fd,&byte,1) // Half-close/stop ends capture.
        }
        sendFrame(fd,3,Data("{\"debugSettingsRestored\":true,\"rawTraceRemoved\":true,\"receivedData\":true}".utf8))
        close(fd); stateLock.lock(); closures += 1; stateLock.unlock()
    }
}
AppleVoiceController.socketPath = path
let controller = AppleVoiceController()
var activated = 0, began = 0, ended = 0, samples = 0
AppleVoiceController.testActivation = { activated += 1 }
controller.began = { began += 1 }
controller.ended = { ended += 1 }
controller.samples = { samples += $0.count }
controller.prepare(); spin { controller.prepared }
for iteration in 1...2 {
    controller.start(); spin { began == iteration && samples == iteration*2 }
    controller.finish(); spin { ended == iteration }
}
check(activated == 2,"two separate utterances activate and finish")
BoundApple.delay = 0.2
controller.start(); controller.finish(); spin { ended == 3 }
RunLoop.main.run(until:Date().addingTimeInterval(0.4)); BoundApple.delay = 0
check(activated == 2 && began == 2,"release before socket connection never activates or begins audio")
stateLock.lock(); delayed = true; let before = requests; stateLock.unlock()
controller.start(); spin { stateLock.lock(); defer { stateLock.unlock() }; return requests > before }
controller.finish(); spin { ended == 4 }
check(activated == 2,"release before producer readiness prevents auxiliary activation")
stateLock.lock(); delayed = false; corrupt = true; stateLock.unlock()
controller.start(); spin { ended == 5 }
check(activated == 2 && began == 2,"invalid protocol closes without audio")
stateLock.lock(); corrupt = false; stateLock.unlock()
controller.start(); spin { began == 3 }
controller.stop(); RunLoop.main.run(until:Date().addingTimeInterval(0.3))
check(ended == 5 && !controller.prepared,"stop invalidates callbacks and prepared state")
controller.prepare(); spin { controller.prepared }
controller.start(); spin { began == 4 }
BoundApple.currentAddress = "00:11:22:33:44:55"
spin({ ended == 6 },timeout:3)
check(ended == 6,"switching selected source ends existing capture")
controller.stop()
print("PASS: warm-up, two utterances, early release, late readiness, malformed protocol, stop, source change")
