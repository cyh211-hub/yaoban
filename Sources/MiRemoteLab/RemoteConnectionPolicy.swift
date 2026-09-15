import Foundation

// One attach attempt per observed system connection. A cached UUID is never
// pairing evidence. Failed attempts cannot cause timer-driven pairing prompts.
struct RemoteConnectionPolicy {
    private var attempted = false
    mutating func shouldAttach(hidConnected: Bool, systemConnected: Bool, pairingInvalid: Bool) -> Bool {
        guard hidConnected && systemConnected else { attempted = false; return false }
        guard !pairingInvalid, !attempted else { return false }
        attempted = true
        return true
    }
}
