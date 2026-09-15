// GPL-3.0. Only sends remote PCM to our own hidden HAL output.
import Foundation
import CoreAudio
import AudioToolbox
import RemoteAudioBuffer

enum RemoteAudioDevice {
    static let inputUID = "MiRemoteLabMic_UID"
    static let outputUID = "MiRemoteLabMic_2_UID"
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func id(_ name: String) -> AudioDeviceID {
        let uid = name as CFString
        var pointer = Unmanaged.passUnretained(uid).toOpaque()
        var result: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var property = address(kAudioHardwarePropertyTranslateUIDToDevice)
        let status = withExtendedLifetime(uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, UInt32(MemoryLayout<UnsafeRawPointer>.size), &pointer, &size, &result)
        }
        guard status == noErr else { return 0 }
        return result
    }
    static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<UnsafeRawPointer>.size)
        var property = address(selector)
        guard device != 0, AudioObjectGetPropertyData(device, &property, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
    static var defaultInput: AudioDeviceID {
        var result: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var property = address(kAudioHardwarePropertyDefaultInputDevice)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &result)
        return result
    }
    static func setDefaultInput(_ device: AudioDeviceID) throws {
        guard device != 0 else { throw failure("目标麦克风不在线。") }
        var device = device
        var property = address(kAudioHardwarePropertyDefaultInputDevice)
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        guard result == noErr, defaultInput == device else { throw failure("系统未接受麦克风选择（\(result)）。") }
    }
    static func failure(_ text: String) -> Error { NSError(domain: "RemoteAudio", code: 1, userInfo: [NSLocalizedDescriptionKey:text]) }
}

final class SystemMicrophone {
    var log: (String) -> Void = { _ in }
    var status: (String) -> Void = { _ in }
    var gainDB: Double = 12 { didSet { gainDB = gainDB.isFinite ? min(24, max(0, gainDB)) : 12; pcm.gainDB = gainDB } }
    var restoreURL: URL?
    private var unit: AudioUnit?
    private let ring = MiAudioRingCreate(48000)!
    private var pcm = RemoteVoicePCM()
    private var generation = 0
    private var dropped: UInt32 = 0
    private var submitted = 0
    private var deviceID: AudioDeviceID = 0
    var available: Bool { RemoteAudioDevice.id(RemoteAudioDevice.inputUID) != 0 && RemoteAudioDevice.id(RemoteAudioDevice.outputUID) != 0 }
    var isDefault: Bool { RemoteAudioDevice.string(RemoteAudioDevice.defaultInput, kAudioDevicePropertyDeviceUID) == RemoteAudioDevice.inputUID }
    deinit { stop(); MiAudioRingDestroy(ring) }

    func refresh() {
        let current = RemoteAudioDevice.id(RemoteAudioDevice.outputUID)
        if unit != nil && current != deviceID { stop(); log("系统音频设备发生变化，已关闭旧声音通道。") }
        if !available { status("尚未安装 · 安装后可在系统声音输入中选择") }
        else if isDefault { status(unit == nil ? "已选为系统输入 · 按住遥控器麦克风说话" : "正在传送遥控器声音") }
        else { status("已就绪 · 当前系统输入：\(RemoteAudioDevice.string(RemoteAudioDevice.defaultInput, kAudioObjectPropertyName) ?? "无")") }
    }
    func selectAsDefault() throws {
        guard available else { throw RemoteAudioDevice.failure("请先安装遥控器麦克风组件。") }
        guard !isDefault else { refresh(); return }
        if let restoreURL {
            let previous = RemoteAudioDevice.string(RemoteAudioDevice.defaultInput, kAudioDevicePropertyDeviceUID)
            try PrivateFiles.write(JSONEncoder().encode(previous), to: restoreURL)
        }
        try RemoteAudioDevice.setDefaultInput(RemoteAudioDevice.id(RemoteAudioDevice.inputUID))
        log("系统默认输入已选为：遥控器麦克风。系统声音输出保持原设备。")
        refresh()
    }
    func restoreDefault() throws {
        guard let restoreURL, FileManager.default.fileExists(atPath: restoreURL.path) else { return }
        if isDefault, let previous = try JSONDecoder().decode(String?.self, from: PrivateFiles.read(restoreURL, limit: 4096)) {
            let device = RemoteAudioDevice.id(previous)
            guard device != 0 else { throw RemoteAudioDevice.failure("原麦克风已断开，请在系统声音设置中选择其他输入。") }
            try RemoteAudioDevice.setDefaultInput(device)
            log("已恢复之前的系统输入麦克风。")
        }
        try FileManager.default.removeItem(at: restoreURL)
        refresh()
    }
    @discardableResult func begin(sampleRate: RemoteVoiceSampleRate = .pcm16k) -> Bool {
        // A fast next press must discard the prior session's delayed tail.
        stop(); pcm = RemoteVoicePCM(sampleRate: sampleRate, gainDB: gainDB)
        dropped = 0; submitted = 0
        let device = RemoteAudioDevice.id(RemoteAudioDevice.outputUID)
        guard device != 0 else { refresh(); return false }
        do {
            var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else { throw RemoteAudioDevice.failure("系统音频输出组件不可用。") }
            var created: AudioUnit?
            try check(AudioComponentInstanceNew(component, &created))
            guard let created else { throw RemoteAudioDevice.failure("音频通道创建失败。") }
            unit = created; deviceID = device
            var off: UInt32 = 0, on: UInt32 = 1, target = device
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, 4))
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, 4))
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &target, 4))
            var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var callback = AURenderCallbackStruct(inputProc: { context, _, _, _, frames, data in
                guard let data else { return noErr }
                let buffers = UnsafeMutableAudioBufferListPointer(data)
                guard buffers.count == 1, buffers[0].mNumberChannels == 2, let pointer = buffers[0].mData,
                      buffers[0].mDataByteSize >= frames * 8 else {
                    for buffer in buffers { if let p = buffer.mData { memset(p, 0, Int(buffer.mDataByteSize)) } }
                    return noErr
                }
                _ = MiAudioRingRender(OpaquePointer(context), pointer.assumingMemoryBound(to: Float.self), frames, 2)
                return noErr
            }, inputProcRefCon: UnsafeMutableRawPointer(ring))
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check(AudioUnitInitialize(created))
            try check(AudioOutputUnitStart(created))
            log("系统麦克风传送开始：遥控器 \(pcm.sampleRate.rawValue / 1000) kHz → 48 kHz；增益 \(Int(gainDB)) dB。")
            refresh(); return true
        } catch { stop(); log(error.localizedDescription); status(error.localizedDescription); return false }
    }
    func append(_ samples: [Int16]) {
        guard unit != nil else { return }
        let converted = pcm.process(samples)
        let written = converted.withUnsafeBufferPointer { MiAudioRingWrite(ring, $0.baseAddress, UInt32($0.count)) }
        dropped += UInt32(converted.count) - written
        submitted += samples.count
    }
    func finish() {
        guard unit != nil else { return }
        let ticket = generation
        let wait = min(1.2, Double(MiAudioRingAvailable(ring)) / 48000 + 0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.log("系统麦克风传送结束：\(String(format: "%.2f", Double(self.submitted) / Double(self.pcm.sampleRate.rawValue))) 秒；发送缓存丢弃 \(self.dropped) 帧。")
            self.stop(); self.refresh()
        }
    }
    func stop() {
        generation += 1
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil; deviceID = 0; MiAudioRingReset(ring)
    }
    private func check(_ result: OSStatus) throws {
        guard result == noErr else { throw RemoteAudioDevice.failure("系统麦克风传送失败（\(result)）。") }
    }
}
