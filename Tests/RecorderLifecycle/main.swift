import AppKit

// No hardware or keyboard permissions are required. A cancelled preview must
// return before any event tap, monitor, or physical keyboard probe is started.
let app = NSApplication.shared
let window = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:200),styleMask:[.titled],backing:.buffered,defer:false)
let recorder = ShortcutRecorder()
var logs: [String] = []
var cancellations = 0
recorder.log = { logs.append($0) }
recorder.cancelled = { _ in cancellations += 1 }
recorder.preview = { _ in recorder.cancel("test synchronous preview cancellation") }
recorder.begin(in:window)
precondition(!recorder.isActive && cancellations == 1)
precondition(logs.contains(where: { $0.contains("test synchronous preview cancellation") }))
precondition(!logs.contains(where: { $0.contains("系统录入已启用") || $0.contains("系统事件监听不可用") || $0.contains("键盘原始信号") }), "Cancelled recorder must not start listeners")
recorder.cancel()
precondition(cancellations == 1, "Repeated cancellation must be inert")
print("PASS: synchronous preview cancellation stops recorder initialization before listeners and is idempotent")
