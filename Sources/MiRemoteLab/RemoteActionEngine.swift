// Xiaomi Remote Lab — GPL-3.0.
import Foundation

// Each physical key owns one immutable press cycle. Short/long discrimination
// never emits the short mapping before the physical release is known.
final class RemoteActionEngine {
    static let repeatingSources = ActionTrigger.repeatingSources
    static let repeatDelay = 0.4
    static let repeatInterval = 0.075
    var emit: (UInt16, Bool) -> Void = { _,_ in }
    var repeatKey: (UInt16) -> Void = { _ in }
    private struct Cycle {
        let mode: ActionTrigger
        let shortKeys: [UInt16]
        let longKeys: [UInt16]
        let longDeadline: TimeInterval
        var started: Bool
        var nextRepeat: TimeInterval?
        var keys: [UInt16] { started ? (mode == .shortLong ? longKeys : shortKeys) : [] }
    }
    private var physical = Set<UInt16>()
    private var blocked = Set<UInt16>()
    private var cycles: [UInt16:Cycle] = [:]
    private var pulses: [UInt16] = []
    private var outputs = Set<UInt16>()
    private var generation = 0

    var microphoneHeld: Bool { physical.contains(0x3E) && !blocked.contains(0x3E) }

    func update(_ next: Set<UInt16>, bindings: [UInt16:[UInt16]], repeatEnabled: Bool = true,
                triggers: [UInt16:ActionTrigger] = [:], longBindings: [UInt16:[UInt16]] = [:],
                longPressDelay: Double = 0.6, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let epoch = generation
        let released = physical.subtracting(next), pressed = next.subtracting(physical)
        physical = next
        blocked.formIntersection(next)
        var taps: [[UInt16]] = []
        for source in released.sorted() {
            guard let cycle = cycles.removeValue(forKey:source) else { continue }
            if cycle.mode == .shortLong && !cycle.started {
                // A delayed timer must not misclassify release at/after threshold.
                taps.append(now >= cycle.longDeadline ? cycle.longKeys : cycle.shortKeys)
            }
        }
        syncOutputs()
        guard generation == epoch else { return }
        for keys in taps {
            pulse(keys)
            guard generation == epoch else { return }
        }
        let delay = longPressDelay.isFinite ? min(2,max(0.2,longPressDelay)) : 0.6
        for source in pressed.sorted() where !blocked.contains(source) {
            var mode = triggers[source] ?? ActionTrigger.defaultMode(for:source)
            if mode == .release || (mode == .repeating && !repeatEnabled) { mode = .hold }
            cycles[source] = Cycle(mode:mode,shortKeys:KeyboardKey.normalized(bindings[source] ?? []),
                                   longKeys:KeyboardKey.normalized(longBindings[source] ?? []),
                                   longDeadline:now + delay,started:mode != .shortLong,
                                   nextRepeat:mode == .repeating ? now + Self.repeatDelay : nil)
        }
        syncOutputs()
    }
    func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let epoch = generation
        var repeated = Set<UInt16>()
        for source in cycles.keys.sorted() {
            guard var cycle = cycles[source] else { continue }
            if cycle.mode == .shortLong && !cycle.started && now >= cycle.longDeadline { cycle.started = true }
            if let deadline = cycle.nextRepeat, now >= deadline {
                cycle.nextRepeat = now + Self.repeatInterval
                repeated.formUnion(cycle.keys.filter {
                    guard let key = KeyboardKey.find($0) else { return false }
                    return !key.isModifier && (!key.isMouse || key.isScroll)
                })
            }
            cycles[source] = cycle
        }
        syncOutputs()
        guard generation == epoch else { return }
        for key in KeyboardKey.normalized(Array(repeated)) {
            repeatKey(key)
            guard generation == epoch else { return }
        }
    }
    private func pulse(_ keys: [UInt16]) {
        let epoch = generation
        pulses = keys
        syncOutputs()
        guard generation == epoch else { return }
        pulses = []
        syncOutputs()
    }
    func releaseAll(blocking currentlyHeld: Set<UInt16> = []) {
        generation += 1
        cycles = [:]; pulses = []; blocked = currentlyHeld; physical = currentlyHeld
        syncOutputs()
    }
    private func syncOutputs() {
        let next = Set(cycles.values.flatMap { $0.keys } + pulses)
        let previous = outputs, epoch = generation
        for key in KeyboardKey.normalized(Array(previous.subtracting(next))).reversed() {
            outputs.remove(key); emit(key,false)
            guard generation == epoch else { return }
        }
        for key in KeyboardKey.normalized(Array(next.subtracting(previous))) {
            outputs.insert(key); emit(key,true)
            guard generation == epoch else { return }
        }
    }
}
