import Foundation

func checkAppleVoiceTimingDiagnostics() {
    let keys: Set<String> = ["timestampPastSamples", "timestampFutureSamples",
        "timestampPastMinMilliseconds", "timestampPastMaxMilliseconds",
        "timestampFutureMinMilliseconds", "timestampFutureMaxMilliseconds",
        "timestampOffsetsOverDay", "timestampInvalidOffsets"]
    func encoded(_ value: AppleVoiceTimingDiagnostics) -> [String: Int] {
        do {
            let data = try JSONEncoder().encode(value)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let result = object as? [String: Int] else {
                check(false, "timing diagnostics encode integer fields only")
                return [:]
            }
            check(Set(result.keys) == keys, "timing diagnostic JSON has exactly eight fixed keys")
            check(result.values.allSatisfy { $0 >= 0 }, "timing diagnostic values stay nonnegative")
            return result
        } catch {
            check(false, "timing diagnostics must always encode without nonfinite numbers")
            return [:]
        }
    }

    var value = AppleVoiceTimingDiagnostics()
    check(encoded(value).values.allSatisfy { $0 == 0 }, "empty timing aggregates all start at zero")
    value.observe(lagSeconds: 28_800)
    check(value.timestampPastSamples == 1 && value.timestampFutureSamples == 0,
          "positive eight-hour offset denotes a past packet")
    check(value.timestampPastMinMilliseconds == 28_800_000 &&
          value.timestampPastMaxMilliseconds == 28_800_000,
          "first past sample initializes both min and max")
    value.observe(lagSeconds: -28_800)
    check(value.timestampFutureSamples == 1 && value.timestampFutureMinMilliseconds == 28_800_000 &&
          value.timestampFutureMaxMilliseconds == 28_800_000,
          "negative eight-hour offset denotes a future packet with independent bounds")
    value.observe(lagSeconds: 0.1259)
    value.observe(lagSeconds: -0.0099)
    check(value.timestampPastMinMilliseconds == 125 && value.timestampFutureMinMilliseconds == 9,
          "fractional milliseconds truncate toward zero on either side")
    check(value.timestampPastMaxMilliseconds == 28_800_000 && value.timestampFutureMaxMilliseconds == 28_800_000,
          "smaller later offsets do not lower maxima")
    value.observe(lagSeconds: 0)
    value.observe(lagSeconds: -0.0)
    check(value.timestampPastSamples == 4 && value.timestampFutureSamples == 2 &&
          value.timestampPastMinMilliseconds == 0,
          "zero and negative zero count as past samples")

    var tiny = AppleVoiceTimingDiagnostics()
    tiny.observe(lagSeconds: Double.leastNonzeroMagnitude)
    tiny.observe(lagSeconds: -Double.leastNonzeroMagnitude)
    check(tiny.timestampPastSamples == 1 && tiny.timestampFutureSamples == 1 &&
          tiny.timestampPastMaxMilliseconds == 0 && tiny.timestampFutureMaxMilliseconds == 0,
          "submillisecond offsets retain their direction while truncating to zero")
    tiny.observe(lagSeconds: 0.003)
    tiny.observe(lagSeconds: -0.006)
    check(tiny.timestampPastMinMilliseconds == 0 && tiny.timestampFutureMinMilliseconds == 0 &&
          tiny.timestampPastMaxMilliseconds == 3 && tiny.timestampFutureMaxMilliseconds == 6,
          "a first zero-millisecond sample remains the true minimum")

    var boundary = AppleVoiceTimingDiagnostics()
    boundary.observe(lagSeconds: 86_400)
    boundary.observe(lagSeconds: -86_400)
    check(boundary.timestampOffsetsOverDay == 0, "exactly 24 hours is not over a day")
    boundary.observe(lagSeconds: Double(86_400).nextUp)
    boundary.observe(lagSeconds: -Double(86_400).nextUp)
    check(boundary.timestampOffsetsOverDay == 2, "the first representable offsets beyond a day are counted")
    boundary.observe(lagSeconds: Double.greatestFiniteMagnitude)
    boundary.observe(lagSeconds: -Double.greatestFiniteMagnitude)
    check(boundary.timestampOffsetsOverDay == 4 && boundary.timestampPastSamples == 3 &&
          boundary.timestampFutureSamples == 3, "huge finite offsets safely retain direction and count")
    check(boundary.timestampPastMinMilliseconds == 86_400_000 && boundary.timestampPastMaxMilliseconds == 86_400_000 &&
          boundary.timestampFutureMinMilliseconds == 86_400_000 && boundary.timestampFutureMaxMilliseconds == 86_400_000,
          "all offsets of a day or more are bounded to 86400000 milliseconds")

    let beforeInvalid = encoded(boundary)
    for offset in [Double.nan, Double.infinity, -Double.infinity] { boundary.observe(lagSeconds: offset) }
    check(boundary.timestampInvalidOffsets == 3 && boundary.timestampOffsetsOverDay == 4,
          "NaN and infinities count as invalid without integer conversion")
    let afterInvalid = encoded(boundary)
    check(keys.subtracting(["timestampInvalidOffsets"]).allSatisfy { beforeInvalid[$0] == afterInvalid[$0] },
          "invalid offsets do not change sample counts or millisecond extrema")

    var saturated = AppleVoiceTimingDiagnostics()
    saturated.timestampPastSamples = Int.max
    saturated.timestampFutureSamples = Int.max
    saturated.timestampOffsetsOverDay = Int.max
    saturated.timestampInvalidOffsets = Int.max
    saturated.observe(lagSeconds: Double.greatestFiniteMagnitude)
    saturated.observe(lagSeconds: -Double.greatestFiniteMagnitude)
    saturated.observe(lagSeconds: Double.nan)
    check(saturated.timestampPastSamples == Int.max && saturated.timestampFutureSamples == Int.max &&
          saturated.timestampOffsetsOverDay == Int.max && saturated.timestampInvalidOffsets == Int.max,
          "all observation counters saturate instead of overflowing")
    check(encoded(saturated).count == 8, "saturated counters remain valid fixed integer JSON")
}
