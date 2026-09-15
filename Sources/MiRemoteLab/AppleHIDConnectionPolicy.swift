import Foundation

// One acquisition attempt per observed, live interface set. A failed attempt must
// not retry forever, but a real disconnect or replacement must clear that failure.
// This policy never connects Bluetooth or treats saved pairing data as presence.
struct AppleHIDConnectionPolicy {
    private var lastInterfaces: Set<UInt64>?

    mutating func needsRebuild(liveInterfaces: Set<UInt64>, systemConnected: Bool = true) -> Bool {
        let usable = systemConnected ? liveInterfaces : []
        guard lastInterfaces != usable else { return false }
        lastInterfaces = usable
        return true
    }

    mutating func reset() { lastInterfaces = nil }
}
