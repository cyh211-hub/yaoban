import Foundation

// Fixed numeric aggregates only: no wall-clock timestamps, device IDs or payloads.
struct AppleVoiceTimingDiagnostics: Encodable {
    var timestampPastSamples = 0
    var timestampFutureSamples = 0
    var timestampPastMinMilliseconds = 0
    var timestampPastMaxMilliseconds = 0
    var timestampFutureMinMilliseconds = 0
    var timestampFutureMaxMilliseconds = 0
    var timestampOffsetsOverDay = 0
    var timestampInvalidOffsets = 0

    mutating func observe(lagSeconds: Double) {
        guard lagSeconds.isFinite else {
            if timestampInvalidOffsets < Int.max { timestampInvalidOffsets += 1 }
            return
        }

        let magnitude = abs(lagSeconds)
        if magnitude > 86_400, timestampOffsetsOverDay < Int.max {
            timestampOffsetsOverDay += 1
        }
        // Clamp before multiplying or converting: even the largest finite Double
        // must not overflow the multiplication or trap during conversion to Int.
        let boundedSeconds = min(magnitude, 86_400)
        let milliseconds = Int((boundedSeconds * 1_000).rounded(.towardZero))
        if lagSeconds >= 0 {
            timestampPastMinMilliseconds = timestampPastSamples == 0
                ? milliseconds : min(timestampPastMinMilliseconds, milliseconds)
            timestampPastMaxMilliseconds = max(timestampPastMaxMilliseconds, milliseconds)
            if timestampPastSamples < Int.max { timestampPastSamples += 1 }
        } else {
            timestampFutureMinMilliseconds = timestampFutureSamples == 0
                ? milliseconds : min(timestampFutureMinMilliseconds, milliseconds)
            timestampFutureMaxMilliseconds = max(timestampFutureMaxMilliseconds, milliseconds)
            if timestampFutureSamples < Int.max { timestampFutureSamples += 1 }
        }
    }
}
