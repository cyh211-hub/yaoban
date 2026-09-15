// Xiaomi Remote Lab — GPL-3.0.
import Foundation

enum CaptureProgress: Equatable {
    case waiting
    case holding([UInt16])
    case complete([UInt16])
    case invalid
}

// One overlapping chord, committed only once all of its keys have been released.
struct ShortcutCapture {
    private(set) var held = Set<UInt16>()
    private var chord = Set<UInt16>()
    private var finished = false

    mutating func key(_ usage: UInt16, down: Bool) -> CaptureProgress {
        guard !finished, KeyboardKey.find(usage) != nil else { return .invalid }
        var next = held
        if down { next.insert(usage) } else { next.remove(usage) }
        return transition(next)
    }
    mutating func modifiers(_ modifiers: Set<UInt16>) -> CaptureProgress {
        guard !finished, modifiers.allSatisfy({ (0xE0...0xE7).contains($0) }) else { return .invalid }
        return transition(held.filter { !(0xE0...0xE7).contains($0) }.union(modifiers))
    }
    private mutating func transition(_ next: Set<UInt16>) -> CaptureProgress {
        // Reject a sequence such as Command-C then V while Command stays held.
        if !next.subtracting(chord).isEmpty && !chord.subtracting(held).isEmpty {
            finished = true; return .invalid
        }
        held = next
        chord.formUnion(next)
        guard chord.count <= 9 else { finished = true; return .invalid }
        if held.isEmpty {
            if chord.isEmpty { return .waiting }
            finished = true; return .complete(KeyboardKey.normalized(Array(chord)))
        }
        return .holding(KeyboardKey.normalized(Array(chord)))
    }
}

// A raw fallback may capture one modifier only. It must never mistake a
// swallowed shortcut (Command + a letter) for a standalone Command press.
struct PhysicalModifierCapture {
    private var usage: UInt16?
    private var pressed = false
    private var released = false
    private var rejected = false
    var candidate: UInt16? { pressed && released && !rejected ? usage : nil }
    mutating func ordinaryKeyDown() { rejected = true }
    mutating func modifier(_ key: UInt16, down: Bool) {
        guard (0xE0...0xE7).contains(key), !released else { rejected = true; return }
        if down {
            if let usage, usage != key { rejected = true }
            else { usage = key; pressed = true }
        } else if pressed && usage == key { released = true }
        else { rejected = true }
    }
}
