// GPL-3.0. Offline decoder only. No Bluetooth, microphone, HAL, or filesystem access.
// Built against the official libopus headers by scripts/test-apple-voice.sh.
import Foundation

final class AppleVoiceDecoder {
    enum Failure: Error { case codec(Int32), unexpectedFrameLength(Int32) }
    static let sampleRate: Int32 = 48_000
    static let frameSamples: Int32 = 960
    private let codec: OpaquePointer
    private var sequence = AppleVoiceSequence()

    init() throws {
        var error: Int32 = 0
        guard let codec = opus_decoder_create(Self.sampleRate, 1, &error) else {
            throw Failure.codec(error)
        }
        guard error == 0 else {
            opus_decoder_destroy(codec)
            throw Failure.codec(error)
        }
        self.codec = codec
    }

    deinit { opus_decoder_destroy(codec) }

    // Call serially. A future live transport must reset on Siri release, disconnect,
    // selected-device change, stale capture, or a new authenticated connection.
    func reset() throws {
        sequence.reset()
        let result = opus_decoder_init(codec, Self.sampleRate, 1)
        guard result == 0 else { throw Failure.codec(result) }
    }

    func consume(reportID: UInt8, payload: Data) throws -> [Int16] {
        guard let report = AppleVoiceReport.parse(reportID: reportID, payload: payload) else { return [] }
        switch report {
        case .ended:
            try reset()
            return []
        case let .frame(number, packet):
            let step = sequence.receive(number)
            if step == .discard { return [] }
            do {
                var output: [Int16] = []
                switch step {
                case let .decode(missing):
                    for _ in 0..<missing { output += try decode(nil) }
                case .resync:
                    try reset()
                    _ = sequence.receive(number)
                case .first, .discard: break
                }
                output += try decode(packet)
                return output
            } catch {
                // Do not carry failed decoder state into the next packet or return
                // a partial concealment burst when decoding the real packet failed.
                try reset()
                throw error
            }
        }
    }

    private func decode(_ packet: Data?) throws -> [Int16] {
        var samples = [Int16](repeating: 0, count: Int(Self.frameSamples))
        let count: Int32
        if let packet {
            count = packet.withUnsafeBytes { raw in
                samples.withUnsafeMutableBufferPointer { output in
                    opus_decode(codec, raw.bindMemory(to: UInt8.self).baseAddress,
                                Int32(packet.count), output.baseAddress!, Self.frameSamples, 0)
                }
            }
        } else {
            count = samples.withUnsafeMutableBufferPointer {
                opus_decode(codec, nil, 0, $0.baseAddress!, Self.frameSamples, 0)
            }
        }
        guard count >= 0 else { throw Failure.codec(count) }
        guard count == Self.frameSamples else { throw Failure.unexpectedFrameLength(count) }
        return samples
    }
}
