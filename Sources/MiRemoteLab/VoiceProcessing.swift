// GPL-3.0. Speech gain and DC/low-frequency cleanup, not a denoising codec.
import Foundation

enum RemoteVoiceSampleRate: Int { case pcm16k = 16000, pcm48k = 48000 }

struct VoiceProcessing {
    var gainDB: Double = 12
    let sampleRate: RemoteVoiceSampleRate
    init(gainDB: Double = 12, sampleRate: RemoteVoiceSampleRate = .pcm16k) {
        self.gainDB = gainDB; self.sampleRate = sampleRate
    }
    private var previousInput = 0.0
    private var previousOutput = 0.0
    private var count = 0
    mutating func reset() { previousInput = 0; previousOutput = 0; count = 0 }
    mutating func process(_ samples: [Int16]) -> [Float] {
        let gain = pow(10, min(24, max(0, gainDB.isFinite ? gainDB : 12)) / 20)
        // 70 Hz first-order high pass, persistent across Bluetooth packets.
        let alpha = exp(-2 * Double.pi * 70 / Double(sampleRate.rawValue))
        return samples.map { sample in
            let x = Double(sample) / 32768
            let filtered = alpha * (previousOutput + x - previousInput)
            previousInput = x; previousOutput = filtered
            count += 1
            let y = filtered * gain * min(1, Double(count) / (Double(sampleRate.rawValue) * 0.008))
            // Soft knee near full scale; ordinary speech below 0.85 is unchanged.
            let a = abs(y)
            let limited = a <= 0.85 ? a : 0.85 + 0.15 * tanh((a - 0.85) / 0.15)
            return Float(y < 0 ? -limited : limited)
        }
    }
}

struct VoiceUpsampler {
    private var previous: Float?
    mutating func reset() { previous = nil }
    // The input is fixed 16 kHz, and our dedicated HAL driver is fixed 48 kHz.
    // Keep interpolation continuous over 120-byte ADPCM frame boundaries.
    mutating func process(_ samples: [Float]) -> [Float] {
        var result: [Float] = []; result.reserveCapacity(samples.count * 3)
        for x in samples {
            let p = previous ?? x
            result.append(p + (x - p) / 3)
            result.append(p + (x - p) * 2 / 3)
            result.append(x); previous = x
        }
        return result
    }
}

// Both source formats feed the same 48 kHz HAL stream. Apple PCM must never
// pass through Xiaomi's 3x interpolator or its duration/pitch would be wrong.
struct RemoteVoicePCM {
    let sampleRate: RemoteVoiceSampleRate
    var gainDB: Double { get { processor.gainDB } set { processor.gainDB = newValue } }
    private var processor: VoiceProcessing
    private var upsampler = VoiceUpsampler()
    init(sampleRate: RemoteVoiceSampleRate = .pcm16k, gainDB: Double = 12) {
        self.sampleRate = sampleRate
        processor = VoiceProcessing(gainDB: gainDB, sampleRate: sampleRate)
    }
    mutating func process(_ samples: [Int16]) -> [Float] {
        let filtered = processor.process(samples)
        return sampleRate == .pcm16k ? upsampler.process(filtered) : filtered
    }
}
