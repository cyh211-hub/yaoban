import Foundation
import Darwin
// Ordinary-user, selected-device auxiliary write. The parent kills this helper
// after five seconds and never grants it root or access to another binding.
guard getuid() != 0, CommandLine.arguments.count == 2,
      CommandLine.arguments[1] == "--activate" else { exit(2) }
do {
    let bound = try BoundApple.resolve()
    let result = try AppleVoiceActivationProbe.run(bound: bound, inspectOnly: false)
    guard result.status == "submitted-audio-unverified" else { exit(3) }
    print("activated")
} catch { exit(3) }
