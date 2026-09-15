import AppKit

// The receiver is an observer/filter in a shared event stream, not a delivery
// acknowledgement. An earlier input-method tap may consume a posted shortcut.
protocol KeyboardEventChannel: AnyObject {
    var hasAccess: Bool { get }
    var isEnabled: Bool { get }
    var currentFlags: UInt64 { get }
    func physicalSnapshot(for keys: Set<UInt16>) -> Set<UInt16>
    func start(observing outputs: Set<UInt16>, _ receive: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) -> Bool
    func includeObservation(for outputs: Set<UInt16>) -> Bool
    func enable()
    func post(_ event: CGEvent)
    func stop()
}

// A key-only action does not receive pointer movement or scroll events. A held
// modifier also needs click/drag flags; a held mouse button needs pointer motion.
enum KeyboardObservation {
    static func mask(for outputs: Set<UInt16>) -> CGEventMask {
        var types = Set<CGEventType>()
        let keys = outputs.compactMap(KeyboardKey.find)
        if keys.contains(where: { !$0.isMouse }) { types.formUnion([.keyDown,.keyUp,.flagsChanged]) }
        if keys.contains(where: { $0.isMouse || $0.isModifier }) {
            types.formUnion([.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,
                             .otherMouseDown,.otherMouseUp,.scrollWheel,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged])
        }
        if keys.contains(where: { $0.isMouse && !$0.isScroll }) { types.insert(.mouseMoved) }
        // Track physical modifiers even during an ordinary keyboard/mouse action.
        if !outputs.isEmpty { types.insert(.flagsChanged) }
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }
}

final class QuartzKeyboardEventChannel: KeyboardEventChannel {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var receive: ((CGEventType, CGEvent) -> Unmanaged<CGEvent>?)?
    private var outputs: Set<UInt16> = []
    var hasAccess: Bool { CGPreflightPostEventAccess() && CGPreflightListenEventAccess() }
    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } == true }
    var currentFlags: UInt64 { CGEventSource.flagsState(.hidSystemState).rawValue }
    func physicalSnapshot(for keys: Set<UInt16>) -> Set<UInt16> {
        var held = Set(keys.compactMap(KeyboardKey.find).filter { !$0.isMouse && CGEventSource.keyState(.hidSystemState, key: $0.code) }.map(\.usage))
        for (usage, button): (UInt16, CGMouseButton) in [(0xF101, .left), (0xF102, .right), (0xF103, .center)] {
            if keys.contains(usage), CGEventSource.buttonState(.hidSystemState, button: button) { held.insert(usage) }
        }
        return held
    }
    func start(observing outputs: Set<UInt16>, _ receive: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) -> Bool {
        stop()
        guard hasAccess, !outputs.isEmpty else { return false }
        self.outputs = outputs
        self.receive = receive
        let mask = KeyboardObservation.mask(for:outputs)
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<QuartzKeyboardEventChannel>.fromOpaque(context).takeUnretainedValue().receive?(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { stop(); return false }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        enable()
        return isEnabled
    }
    func includeObservation(for newOutputs: Set<UInt16>) -> Bool {
        let combined = outputs.union(newOutputs)
        guard let receive, isEnabled else { return false }
        if KeyboardObservation.mask(for:combined) == KeyboardObservation.mask(for:outputs) { outputs = combined; return true }
        return start(observing:combined,receive)
    }
    func enable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
    func post(_ event: CGEvent) { event.post(tap: .cghidEventTap) }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil; receive = nil; outputs = []
    }
    deinit { stop() }
}
