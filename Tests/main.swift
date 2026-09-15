import Foundation
import AppKit
import RemoteAudioBuffer

func check(_ condition: @autoclosure () throws -> Bool, _ description: String) {
    do { guard try condition() else { fatalError(description) } }
    catch { fatalError("\(description): \(error)") }
}
check(RemoteReport.parse(id: 1, data: Data([1, 0x28, 0, 0, 0, 0, 0])) == [0x28], "OK report with ID")
check(RemoteReport.parse(id: 1, data: Data([0x65, 0, 0x52, 0, 0, 0])) == [0x65, 0x52], "menu + up report")
check(RemoteReport.parse(id: 1, data: Data(repeating: 0, count: 6)) == [], "release report")
check(RemoteReport.parse(id: 1, data: Data([0x28, 0, 0])) == nil, "reject truncated report")
check(RemoteReport.parse(id: 1, data: Data([1, 0, 0, 0, 0, 0])) == nil, "reject HID rollover")
check(RemoteReport.parse(id: 6, data: Data(repeating: 0, count: 6)) == nil, "ignore vendor report")

let decoder = IMAADPCMDecoder()
// Fixture independently decoded with Python 3.9's audioop.adpcm2lin.
let encoded = Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0])
let expected: [Int16] = [1, 4, 8, 15, 27, 47, 88, 82, 66, 41, 10, -28, -84, -181, -380, -352]
check(decoder.decode(encoded) == expected, "IMA ADPCM nibble order and signs")
var accumulator = FrameAccumulator()
check(accumulator.append(Data([1, 2]), frameSize: 3).isEmpty, "retain fragmented audio")
check(accumulator.append(Data([3, 4, 5, 6]), frameSize: 3) == [Data([1, 2, 3]), Data([4, 5, 6])], "reassemble fragmented frames")
let wave = WaveFile.encode(expected)
try wave.write(to: URL(fileURLWithPath: ".build/test-fixture.wav"))
print("PASS: HID fixtures, malformed reports, independent ADPCM vector, fragmented audio, WAV fixture")

let defaults = MappingConfiguration()
check(defaults.bindings[0x3E] == [0xE7], "microphone maps to RIGHT Command")
check(defaults.bindings[0x28] == [0xE2,0x28], "OK retains current left Option + Return")
check(defaults.bindings[0x66] == [0x28], "Power defaults to Return")
check(KeyboardKey.find(0xE7)?.code == 54 && KeyboardKey.find(0xE3)?.code == 55, "distinguish left/right Command")
check(try! JSONDecoder().decode(MappingConfiguration.self, from: JSONEncoder().encode(defaults)).validated().bindings == defaults.bindings, "configuration round trip")
let engine = ChordEngine()
var events: [String] = []
engine.emit = { usage, down in events.append("\(usage):\(down ? "down" : "up")") }
let plan = MappingPlan(bindings: defaults.bindings)
check(plan.native[0x3E] == 0, "microphone F5 must be suppressed, never natively converted to a modifier")
check(plan.native[0x28] == 0 && plan.software[0x28] == [0xE2,0x28], "OK is suppressed and sends explicit Option + Return")
check(plan.software[0x3E] == [0xE7], "right Command is an explicit software binding")
engine.update([0x28], bindings: plan.software)
engine.update([], bindings: plan.software)
check(events == ["226:down","40:down","40:up","226:up"], "default OK sends a complete Option + Return, never plain Return")
events = []
engine.update([0x66], bindings: plan.software)
engine.update([], bindings: plan.software)
check(events == ["40:down","40:up"], "default Power sends one Return with no modifier")
events = []
let originalPlan = MappingPlan(bindings: [:])
engine.update([0x52], bindings: originalPlan.software)
engine.update([], bindings: originalPlan.software)
check(events.isEmpty && originalPlan.native[0x52] == nil, "unconfigured sources retain native behavior and are not injected")
engine.update([0x3E], bindings: plan.software)
engine.update([0x3E], bindings: plan.software)
engine.update([], bindings: plan.software)
check(events == ["231:down","231:up"], "mic sends only right Command down/up, no F5 and no repeat")

// Reproduce the remote's Back report and the user's saved Back -> Backspace
// binding, all the way to CGEvent construction without posting real keystrokes.
let backPlan = MappingPlan(bindings: [0xF1: [0x2A]])
check(backPlan.native[0xF1] == 0, "Back must not rely on the ineffective native 0xF1 -> Backspace replacement")
let backEngine = ChordEngine()
var backEvents: [CGEvent] = []
backEngine.emit = { usage, down in
    backEvents.append(KeyboardEmitter.makeEvent(usage: usage, down: down, flags: 0, source: nil, receipt: 80)!)
}
let backDown = RemoteReport.parse(id: 1, data: Data([0xF1, 0, 0, 0, 0, 0]))!
let backUp = RemoteReport.parse(id: 1, data: Data(repeating: 0, count: 6))!
backEngine.update(backDown, bindings: backPlan.software)
backEngine.update(backDown, bindings: backPlan.software)
backEngine.update(backUp, bindings: backPlan.software)
check(backEvents.count == 2, "Back press/hold/release delivers exactly one complete target key stroke")
check(backEvents.map { $0.type } == [.keyDown, .keyUp], "Backspace down/up order")
check(backEvents.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 51 }, "Back produces backward Delete, not Forward Delete or Return")
backEngine.update(backDown, bindings: backPlan.software)
backEngine.releaseAll(blocking: backDown)
backEngine.update(backDown, bindings: backPlan.software)
check(backEvents.count == 4 && backEvents.last?.type == .keyUp, "stopping while Back is held releases Backspace without retriggering")
check(MappingPlan(bindings: [0xF1: []]).software.isEmpty, "disabled Back must not emit a key")
check(MappingPlan(bindings: [:]).native[0xF1] == nil, "Keep Original leaves Back untouched")
print("PASS: raw Back report -> backward Delete press/hold/release, stop while held, disabled and original behavior")

events = []
let chords: [UInt16: [UInt16]] = [0x65:[0xE7,0x06],0x52:[0xE7,0x19]]
engine.update([0x65], bindings: chords)
check(events == ["231:down","6:down"], "modifier goes down before letter")
engine.update([0x65], bindings: chords)
check(events.count == 2, "holding a key does not toggle or retrigger")
engine.update([0x65,0x52], bindings: chords)
engine.update([0x52], bindings: chords)
check(events == ["231:down","6:down","25:down","6:up"], "shared modifier stays held")
engine.update([], bindings: chords)
check(Array(events.suffix(2)) == ["25:up","231:up"], "release letter before modifier")
events = []
engine.update([0x65], bindings: chords)
engine.update([0x65], bindings: [0x65:[0xE3,0x04]])
engine.update([], bindings: [:])
check(events == ["231:down","6:down","6:up","231:up"], "held chord owns original binding even after config changes")
events = []
engine.update([0x65], bindings: chords)
engine.releaseAll(blocking: [0x65])
engine.update([0x65], bindings: chords)
check(events == ["231:down","6:down","6:up","231:up"], "disable releases everything without retriggering held source")
engine.update([], bindings: chords)
engine.update([0x65], bindings: chords)
engine.releaseAll()
check(Array(events.suffix(4)) == ["231:down","6:down","6:up","231:up"], "disconnect releases all owned keys")

var outputState = KeyboardOutputState()
check(outputState.virtualEdge(0xE7, down: true), "right Command first press emits")
let rightDownFlags = outputState.flags(preserving: 0x100)
check(rightDownFlags == 0x100110, "right Command has the Command flag and RIGHT side only, no Option")
check(!outputState.virtualEdge(0xE7, down: true), "duplicate right Command press does not emit")
check(outputState.virtualEdge(0xE7, down: false), "release must emit even if HID state contains our own injected press")
let rightUpFlags = outputState.flags(preserving: rightDownFlags)
check(rightUpFlags == 0x100, "release clears stale injected flags")
outputState.physicalEdge(0xE3, down: true)
check(outputState.virtualEdge(0xE7, down: true), "left physical and right virtual Command stay distinct")
check(outputState.flags(preserving: 0x100) == 0x100118, "both Command sides held")
check(outputState.virtualEdge(0xE7, down: false), "right release with physical left held")
check(outputState.flags(preserving: 0x100118) == 0x100108, "right release preserves physical left")
outputState.physicalEdge(0xE7, down: true)
check(!outputState.virtualEdge(0xE7, down: true), "do not double-press physically held right Command")
check(!outputState.virtualEdge(0xE7, down: false), "do not release physically held right Command")
outputState.physicalEdge(0xE7, down: false)
outputState.physicalEdge(0xE3, down: false)

let eventSource = CGEventSource(stateID: .privateState)
for (down, flags) in [(true, rightDownFlags), (false, rightUpFlags)] {
    let event = KeyboardEmitter.makeEvent(usage: 0xE7, down: down, flags: flags, source: eventSource, receipt: 42)!
    check(event.getIntegerValueField(.keyboardEventKeycode) == 54, "actual CGEvent must address right Command, never F5 code 96 or right Option code 61")
    check(event.type == .flagsChanged && event.flags.rawValue == flags, "actual modifier event type and flags")
    check(event.getIntegerValueField(.eventSourceUserData) == KeyboardEmitter.tagPrefix | 42, "output receipt survives event construction")
}
let enterEvent = KeyboardEmitter.makeEvent(usage: 0x28, down: true, flags: 0, source: eventSource, receipt: 43)!
check(enterEvent.type == .keyDown && enterEvent.getIntegerValueField(.keyboardEventKeycode) == 36, "normal keys still use keyDown")
print("PASS: F5 suppression, single modifier down/hold/up, physical ownership, actual CGEvent right-side flags (not posted)")

// Model an input method consuming every shortcut before our observer. No test
// event is sent to macOS; exercise the real emitter and press engine together.
final class ConsumingKeyboardChannel: KeyboardEventChannel {
    var hasAccess = true
    var isEnabled = false
    var currentFlags: UInt64 = 0
    var snapshot: Set<UInt16> = []
    var snapshotReads = 0
    var starts = 0
    var stops = 0
    var observesPosts = false
    var snapshotRequests: [Set<UInt16>] = []
    var events: [CGEvent] = []
    var receiver: ((CGEventType, CGEvent) -> Unmanaged<CGEvent>?)?
    func physicalSnapshot(for keys: Set<UInt16>) -> Set<UInt16> { snapshotReads += 1; snapshotRequests.append(keys); return snapshot.intersection(keys) }
    func start(observing outputs: Set<UInt16>, _ receive: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) -> Bool {
        starts += 1; receiver = receive; isEnabled = hasAccess; return isEnabled
    }
    func includeObservation(for outputs: Set<UInt16>) -> Bool { isEnabled }
    func enable() { isEnabled = true }
    func post(_ event: CGEvent) {
        events.append(event.copy()!)
        if observesPosts { _ = receiver?(event.type, event) }
    }
    func stop() { stops += 1; isEnabled = false; receiver = nil }
}
do {
    let channel = ConsumingKeyboardChannel()
    var scheduled: [() -> Void] = []
    let emitter = KeyboardEmitter(channel: channel, scheduleReceiptCheck: { scheduled.append($0) })
    let engine = RemoteActionEngine()
    var failures = 0
    emitter.failed = { _ in failures += 1; engine.releaseAll(blocking: [0x3E]) }
    engine.emit = { emitter.send($0, down: $1) }
    engine.repeatKey = { emitter.repeatKey($0) }
    func expire() { let checks = scheduled; scheduled = []; checks.forEach { $0() } }
    check(emitter.start(), "fake channel starts without system input")
    for press in 0..<10 {
        let before = channel.events.count
        engine.update([0x3E], bindings: [0x3E: [0xE7]])
        expire()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        check(engine.microphoneHeld && emitter.isRunning && emitter.failure == nil && failures == 0,
              "missing acknowledgement must not cancel held speech or disable subsequent press \(press)")
        check(channel.events.count == before + 1, "no forced release or replay after consumed shortcut")
        engine.update([], bindings: [0x3E: [0xE7]])
        expire()
        check(!engine.microphoneHeld && channel.events.count == before + 2, "physical release emits exactly one key-up")
        let down = channel.events[before], up = channel.events[before + 1]
        check(down.type == .flagsChanged && down.getIntegerValueField(.keyboardEventKeycode) == 54 && down.flags.rawValue & 0x10 != 0,
              "consumed microphone press remains right Command")
        check(up.type == .flagsChanged && up.flags.rawValue & 0x10 == 0, "consumed microphone release clears right Command")
    }
    let beforeRepeat = channel.events.count
    engine.update([0xF1], bindings: [0xF1:[0x2A]], now: 0)
    expire(); engine.tick(now: 0.5); expire()
    engine.update([], bindings: [0xF1:[0x2A]], now: 1)
    check(channel.events.count == beforeRepeat + 3 && channel.events[beforeRepeat + 1].getIntegerValueField(.keyboardEventAutorepeat) == 1,
          "backspace repeat survives missing receipts and releases once")
    // A stale failure callback must not cancel a newly recovered press.
    emitter.send(0xE7, down: true)
    channel.hasAccess = false; expire()
    check(emitter.failure != nil, "actual permission loss remains a hard failure")
    emitter.send(0xE7, down: false)
    let startsBeforeRecovery = channel.starts, stopsBeforeRecovery = channel.stops, readsBeforeRecovery = channel.snapshotReads
    emitter.recover()
    channel.hasAccess = true
    channel.snapshot = [0xE7] // our asynchronous release can still appear in HID
    check(!channel.isEnabled && emitter.start() && channel.starts == startsBeforeRecovery && channel.stops == stopsBeforeRecovery + 1,
          "re-detection removes old channel and prepares output without idle monitoring")
    check(channel.snapshotReads == readsBeforeRecovery, "immediate recovery preserves physical ownership rather than sampling synthetic key-up")
    engine.update([0x3E], bindings: [0x3E:[0xE7]])
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    check(failures == 0 && emitter.isRunning && engine.microphoneHeld && channel.starts == startsBeforeRecovery + 1, "next press rebuilds channel and old queued failure cannot poison it")
    expire()
    engine.update([], bindings: [0x3E:[0xE7]])
    channel.observesPosts = true
    emitter.send(0x28, down: true); emitter.send(0x28, down: false); expire()
    check(emitter.isRunning && emitter.failure == nil, "visible receipts resume without replay or permanent failure")
    emitter.send(0xE7, down: true)
    let changed = channel.events.last!.copy()!
    changed.setIntegerValueField(.eventSourceUserData, value: KeyboardEmitter.tagPrefix | 0xFFFF)
    // Unknown/late receipts are harmless; actual pending mismatch still fails.
    _ = channel.receiver?(changed.type, changed)
    channel.observesPosts = false
    emitter.send(0x28, down: true)
    let mismatch = channel.events.last!.copy()!
    mismatch.setIntegerValueField(.keyboardEventKeycode, value: 96)
    _ = channel.receiver?(mismatch.type, mismatch)
    check(emitter.failure != nil, "observed wrong key identity still suspends output")
    emitter.stop(); expire()
    check(!emitter.isRunning && emitter.failure == nil, "stop discards pending checks and observation state")
}
print("PASS: consumed shortcuts preserve 10 held speech cycles, repeat/release, real failure safety, channel rebuild and stale callback isolation (no system events posted)")

var voice = VoiceProcessing()
let speechTone: [Int16] = (0..<16000).map { Int16(2000 * sin(Double($0) * 2 * .pi * 440 / 16000)) }
let continuous = voice.process(speechTone)
var chunkedProcessor = VoiceProcessing()
var chunked: [Float] = []
for start in stride(from: 0, to: speechTone.count, by: 240) { chunked += chunkedProcessor.process(Array(speechTone[start..<min(start+240,speechTone.count)])) }
check(continuous == chunked, "voice filtering must have no Bluetooth frame-boundary seams")
check(continuous.allSatisfy { $0.isFinite && abs($0) <= 1 }, "voice output must be finite and bounded")
check(continuous.suffix(1000).map { abs($0) }.max()! > 0.2, "12 dB gain raises quiet speech")
voice.reset()
check(voice.process(Array(repeating: 0, count: 480)) == Array(repeating: 0, count: 480), "silence stays silent")
var upsampler = VoiceUpsampler()
check(upsampler.process([0,0.3]).count == 6, "16k to 48k conversion produces exactly three samples per input")
let nextUpsample = upsampler.process([0.6])
check(abs(nextUpsample[0] - 0.4) < 0.000001 && abs(nextUpsample[2] - 0.6) < 0.000001, "resampling spans packet boundaries continuously")
var applePCM = RemoteVoicePCM(sampleRate: .pcm48k)
var xiaomiPCM = RemoteVoicePCM()
let appleTone: [Int16] = (0..<960).map { Int16(2000 * sin(Double($0) * 2 * .pi * 440 / 48000)) }
let appleOutput = applePCM.process(appleTone)
check(appleOutput.count == 960, "20ms Apple PCM remains 20ms at the HAL output")
check(xiaomiPCM.process(Array(speechTone.prefix(320))).count == 960, "20ms Xiaomi PCM still resamples to 20ms HAL output")
var appleSplit = RemoteVoicePCM(sampleRate: .pcm48k)
let splitOutput = appleSplit.process(Array(appleTone.prefix(237))) + appleSplit.process(Array(appleTone.dropFirst(237)))
check(appleOutput == splitOutput, "Apple processing preserves state over packet boundaries")
check(appleOutput.allSatisfy { $0.isFinite && abs($0) <= 1 }, "Apple audio remains finite and bounded")
var extremePCM = RemoteVoicePCM(sampleRate: .pcm48k, gainDB: 24)
check(extremePCM.process([Int16.min, Int16.max]).allSatisfy { $0.isFinite && abs($0) <= 1 }, "full scale Apple input is limited safely")
let ring = MiAudioRingCreate(4)!
var mono: [Float] = [0.1,0.2,0.3,0.4,0.5]
check(mono.withUnsafeBufferPointer { MiAudioRingWrite(ring,$0.baseAddress,5) } == 4, "full ring drops excess instead of overwriting unread audio")
var stereo = [Float](repeating: -1, count: 12)
check(stereo.withUnsafeMutableBufferPointer { MiAudioRingRender(ring,$0.baseAddress,6,2) } == 4, "ring reports consumed frames")
check(stereo == [0.1,0.1,0.2,0.2,0.3,0.3,0.4,0.4,0,0,0,0], "mono is duplicated to both channels and starvation fills with silence")
check(MiAudioRingAvailable(ring) == 0, "read consumes exactly once")
check(mono.withUnsafeBufferPointer { MiAudioRingWrite(ring,$0.baseAddress,2) } == 2, "ring wraps after read")
MiAudioRingReset(ring)
check(MiAudioRingAvailable(ring) == 0, "session reset discards previous voice")
MiAudioRingDestroy(ring)
print("PASS: continuous voice gain/filter, bounded silence, 16k→48k interpolation, ring overflow/underflow, stereo duplication, session reset")

let original = MappingPair(source: 10, destination: 11)
let ours = MappingPair(source: 10, destination: 12)
let unrelated = MappingPair(source: 20, destination: 21)
let external = MappingPair(source: 10, destination: 13)
let snapshot = MappingSnapshot(registryID: 1, original: [original], installed: [ours])
check(snapshot.restoring(in: [ours,unrelated]) == [unrelated,original], "restore existing mapping while preserving unrelated key")
check(snapshot.restoring(in: [external,unrelated]) == [external,unrelated], "never overwrite a newer external mapping")
check(MappingSnapshot(registryID: 1, original: [], installed: [ours]).restoring(in: [ours,unrelated]) == [unrelated], "restore originally absent mapping")
print("PASS: right-Command default, down/hold/up, shared modifiers, edits while held, disconnect cleanup, mapping restoration")

check(ModifierIdentity.pressed(code: 54, flags: 0x100010) == 0xE7, "identify right Command")
check(ModifierIdentity.pressed(code: 61, flags: 0x80040) == 0xE6, "identify right Option / Alt separately")
check(ModifierIdentity.pressed(code: 55, flags: 0x100008) == 0xE3, "keep left Command distinct")
check(ModifierIdentity.pressed(code: 54, flags: 0x80040) == nil, "reject key code / flag disagreement")
check(ModifierIdentity.pressed(code: 54, flags: 0x100018) == nil, "reject both Command keys held")
check(ModifierIdentity.pressed(code: 54, flags: 0x180050) == nil, "reject two modifiers held")
check(ModifierIdentity.pressed(code: 54, flags: 0) == nil, "release is not a new press")
check(ModifierIdentity.pressed(code: 0, flags: 0x100010) == nil, "ordinary keys cannot become modifier calibration")
print("PASS: calibration distinguishes right/left Command and Option, rejects conflicting codes and multi-key input")

var singleCapture = ShortcutCapture()
check(singleCapture.key(0x28, down: false) == .waiting, "stray release cannot save a binding")
check(singleCapture.key(0x28, down: true) == .holding([0x28]), "Return starts recording without saving")
check(singleCapture.key(0x28, down: true) == .holding([0x28]), "repeat key-down is not another shortcut")
check(singleCapture.key(0x28, down: false) == .complete([0x28]), "Return saves on release")
check(singleCapture.key(0x04, down: true) == .invalid, "finished recorder cannot capture later typing")
var modifierCapture = ShortcutCapture()
check(modifierCapture.modifiers([0xE7]) == .holding([0xE7]), "right Command alone can be recorded")
check(modifierCapture.modifiers([]) == .complete([0xE7]), "save modifier-only binding on release")
var chordCapture = ShortcutCapture()
check(chordCapture.modifiers([0xE7,0xE1]) == .holding([0xE1,0xE7]), "preserve modifier sides in combination")
check(chordCapture.key(0x14, down: true) == .holding([0xE1,0xE7,0x14]), "record Shift + right Command + Q")
check(chordCapture.modifiers([]) == .holding([0xE1,0xE7,0x14]), "releasing modifiers first does not save early")
check(chordCapture.key(0x14, down: false) == .complete([0xE1,0xE7,0x14]), "save after all keys are released")
var sequenceCapture = ShortcutCapture()
_ = sequenceCapture.modifiers([0xE3])
_ = sequenceCapture.key(0x06, down: true)
_ = sequenceCapture.key(0x06, down: false)
check(sequenceCapture.key(0x19, down: true) == .invalid, "reject sequential C then V as a simultaneous shortcut")
var escapeCapture = ShortcutCapture()
_ = escapeCapture.key(0x29, down: true)
check(escapeCapture.key(0x29, down: false) == .complete([0x29]), "Escape remains assignable; mouse button cancels recording")
check(ModifierIdentity.active(flags: 0x100018, eventCode: 55, previous: [0xE7]) == [0xE3,0xE7], "record both Command keys distinctly")
check(ModifierIdentity.active(flags: 0x100000, eventCode: 55, previous: [0xE3,0xE7]) == [0xE7], "fallback can release one side while the other stays held")
check(ModifierIdentity.active(flags: 0, eventCode: 54, previous: [0xE7]).isEmpty, "modifier flag release clears recorded hold")
print("PASS: inline shortcut recording waits for release, preserves sides, supports modifier-only/Escape, rejects sequences")

var rawCapture = PhysicalModifierCapture()
rawCapture.modifier(0xE7, down: true)
check(rawCapture.candidate == nil, "raw fallback requires key release")
rawCapture.modifier(0xE7, down: false)
check(rawCapture.candidate == 0xE7, "raw fallback preserves right Command")
var rawChord = PhysicalModifierCapture()
rawChord.modifier(0xE7, down: true)
rawChord.ordinaryKeyDown()
rawChord.modifier(0xE7, down: false)
check(rawChord.candidate == nil, "never turn a swallowed Command-letter chord into Command alone")
var rawTwoModifiers = PhysicalModifierCapture()
rawTwoModifiers.modifier(0xE7, down: true)
rawTwoModifiers.modifier(0xE5, down: true)
rawTwoModifiers.modifier(0xE5, down: false)
rawTwoModifiers.modifier(0xE7, down: false)
check(rawTwoModifiers.candidate == nil, "multiple raw modifiers need logical system events")
var rawOrphan = PhysicalModifierCapture()
rawOrphan.modifier(0xE7, down: false)
check(rawOrphan.candidate == nil, "a raw release alone cannot be saved")
rawCapture.modifier(0xE7, down: true)
check(rawCapture.candidate == nil, "new input invalidates a pending raw fallback")
print("PASS: blocked standalone modifier fallback requires full stroke and rejects chords, orphan release, and later input")

// Every remote row uses the same recording -> disk -> new-store load -> raw
// HID report -> target down/up pipeline. This posts no input to other apps.
let auditRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mi-mapping-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: auditRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: auditRoot) }
let targets: [[UInt16]] = [[0x28], [0x2A], [0x29], [0x2B], [0x52], [0x04], [0x3F], [0xE7], [0xE6], [0xE0,0x28], [0xE2,0x28], [0xE7,0xE5,0x06]]
let matrixDirectory = auditRoot.appendingPathComponent("matrix")
let matrixStore = MappingStore(directory: matrixDirectory)
_ = try matrixStore.load()
var matrixCases = 0
for source in RemoteReport.names.keys.sorted() {
    for target in targets {
        let normalized = KeyboardKey.normalized(target)
        var capture = ShortcutCapture()
        let modifiers = Set(target.filter { KeyboardKey.find($0)!.isModifier })
        let ordinary = target.filter { !KeyboardKey.find($0)!.isModifier }
        if !modifiers.isEmpty { _ = capture.modifiers(modifiers) }
        for key in ordinary { _ = capture.key(key, down: true) }
        var completed: CaptureProgress = .waiting
        for key in ordinary.reversed() { completed = capture.key(key, down: false) }
        if !modifiers.isEmpty { completed = capture.modifiers([]) }
        check(completed == .complete(normalized), "recorded target must retain all modifier sides and ordinary keys")
        _ = try matrixStore.update(source: source, keys: normalized)
        let reloaded = try MappingStore(directory: matrixDirectory).load().configuration
        check(reloaded.bindings[source] == normalized, "every remote row must survive a new store instance")
        let route = MappingPlan(bindings: reloaded.bindings)
        check(route.native[source] == 0, "every custom source suppresses native output")
        let report = Data([UInt8(source & 255), UInt8(source >> 8),0,0,0,0])
        let rawDown = RemoteReport.parse(id: 1, data: report)!
        var produced: [(UInt16,Bool)] = []
        let pipeline = RemoteActionEngine()
        pipeline.emit = { produced.append(($0,$1)) }
        pipeline.update(rawDown, bindings: route.software)
        pipeline.update(rawDown, bindings: route.software)
        pipeline.update([], bindings: route.software)
        check(produced.map { $0.0 } == normalized + normalized.reversed(), "every source emits exactly the requested keys in down/up order")
        check(produced.map { $0.1 } == Array(repeating:true,count:target.count) + Array(repeating:false,count:target.count), "held reports must not duplicate input")
        var state = KeyboardOutputState()
        for (key, down) in produced {
            _ = state.virtualEdge(key, down: down)
            let flags = state.flags(preserving: 0)
            let event = KeyboardEmitter.makeEvent(usage: key, down: down, flags: flags, source: nil, receipt: 99)!
            check(event.getIntegerValueField(.keyboardEventKeycode) == Int64(KeyboardKey.find(key)!.code), "emitted Mac keycode must match the recorded target")
            check(event.flags.rawValue == flags, "emitted modifiers must match the currently held chord")
        }
        check(state.combined.isEmpty, "no key remains held after the source releases")
        matrixCases += 1
    }
    _ = try matrixStore.update(source: source, keys: [])
    check(try MappingStore(directory: matrixDirectory).load().configuration.bindings[source] == [], "disabled row persists")
    _ = try matrixStore.update(source: source, keys: nil)
    check(try MappingStore(directory: matrixDirectory).load().configuration.bindings[source] == nil, "Keep Original persists without reapplying defaults")
}
print("PASS: \(RemoteReport.names.count) remote buttons × \(targets.count) targets = \(matrixCases) recording/save/reload/output cases; all rows also preserve disabled/original")

let migration = auditRoot.appendingPathComponent("migration")
let legacy = auditRoot.appendingPathComponent("legacy")
try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
let oldConfig = MappingConfiguration(bindings: [0x28:[0xE2,0x28], 0xF1:[0x2A], 0x52:[]])
try JSONEncoder().encode(oldConfig).write(to: legacy.appendingPathComponent("按键设置.json"))
let migrated = MappingStore(directory: migration, legacyDirectory: legacy)
check(try migrated.load().configuration == oldConfig, "migration keeps custom Alt + Return, disabled rows and missing rows exactly")
let requested = try migrated.update(source: 0x28, keys: [0xE0,0x28])
try JSONEncoder().encode(MappingConfiguration()).write(to: legacy.appendingPathComponent("按键设置.json"))
check(try MappingStore(directory: migration, legacyDirectory: legacy).load().configuration == requested, "stale legacy file must never override a migrated user setting")
let twoStores = MappingStore(directory: migration)
_ = try twoStores.load()
_ = try migrated.update(source: 0x66, keys: [0x28])
let combined = try twoStores.update(source: 0x4A, keys: [0x29])
check(combined.bindings[0x66] == [0x28] && combined.bindings[0x28] == [0xE0,0x28], "saving a different row preserves other recently saved rows")

let recovery = MappingStore(directory: auditRoot.appendingPathComponent("recovery"))
_ = try recovery.load()
let previousSave = try recovery.update(source: 0x28, keys: [0xE2,0x28])
_ = try recovery.update(source: 0x28, keys: [0xE0,0x28])
try Data("bad json".utf8).write(to: recovery.url)
let restored = try MappingStore(directory: recovery.directory).load()
check(restored.configuration == previousSave && restored.notice.contains("备份"), "corrupt primary recovers the previous valid save with an explicit notice")
check(try FileManager.default.contentsOfDirectory(atPath: recovery.directory.path).contains { $0.hasPrefix("按键设置-无法读取-") }, "corrupt original is preserved for diagnosis")
let broken = MappingStore(directory: auditRoot.appendingPathComponent("broken"))
try FileManager.default.createDirectory(at: broken.directory, withIntermediateDirectories:true)
let invalidData = Data("not json".utf8)
try invalidData.write(to: broken.url)
do { _ = try broken.load(); fatalError("invalid settings must not silently reset to defaults") } catch {}
check(try Data(contentsOf: broken.url) == invalidData, "failed load leaves the original bytes untouched")
do { try broken.save(defaults); fatalError("save must not overwrite unreadable settings") } catch {}
check(try Data(contentsOf: broken.url) == invalidData, "failed save preserves the unreadable original")
try Data("{\"version\":99,\"bindings\":{}}".utf8).write(to: recovery.url)
do { _ = try recovery.load(); fatalError("newer version must not be replaced by an older backup") } catch MappingStore.StoreError.newerVersion {} 
let clean = MappingStore(directory: auditRoot.appendingPathComponent("clean"))
check(try clean.load().configuration == defaults, "fresh install gets the new OK and Power defaults")
var firstLease: InstanceLease? = InstanceLease()
check(try firstLease!.acquire(in: clean.directory), "first app gets exclusive ownership")
let duplicateLease = InstanceLease()
check(try !duplicateLease.acquire(in: clean.directory), "duplicate app cannot take mapping/settings ownership")
firstLease = nil
check(try duplicateLease.acquire(in: clean.directory), "app can reopen after previous instance exits")
print("PASS: legacy migration, new defaults, stale-file protection, per-row updates, backup recovery, corrupt/newer-file preservation, exclusive instance and relaunch")

let profilesStore = MappingStore(directory: auditRoot.appendingPathComponent("profiles"))
_ = try profilesStore.load()
let programming = try profilesStore.editProfiles { try $0.duplicate(name: "编程") }
let programmingID = programming.selectedID
_ = try profilesStore.update(source: 0xF1, keys: [0x2A])
let player = try profilesStore.editProfiles { try $0.duplicate(name: "播放器") }
let playerID = player.selectedID
_ = try profilesStore.update(source: 0x28, keys: [0x2C])
let ppt = try profilesStore.editProfiles { try $0.duplicate(name: "PPT") }
let pptID = ppt.selectedID
_ = try profilesStore.update(source: 0x28, keys: [0x4E])
let reopenedProfiles = try MappingStore(directory: profilesStore.directory).load()
check(reopenedProfiles.library.selectedID == pptID && reopenedProfiles.configuration.bindings[0x28] == [0x4E], "reopening keeps the selected mode and its keys")
let loadedProgramming = try profilesStore.editProfiles { try $0.select(programmingID) }
check(loadedProgramming.selected.configuration.bindings[0x28] == [0xE2,0x28] && loadedProgramming.selected.configuration.bindings[0xF1] == [0x2A], "programming mode is isolated from later player/PPT edits")
let loadedPlayer = try profilesStore.editProfiles { try $0.select(playerID) }
check(loadedPlayer.selected.configuration.bindings[0x28] == [0x2C], "player mode preserves its own Space mapping")
let renamed = try profilesStore.editProfiles { try $0.renameSelected("视频播放") }
check(renamed.selected.id == playerID && renamed.selected.name == "视频播放", "renaming keeps the same profile and keys")
let beforeBadProfile = try Data(contentsOf: profilesStore.url)
do { _ = try profilesStore.editProfiles { try $0.duplicate(name: "编程") }; fatalError("duplicate names must be rejected") } catch {}
check(try Data(contentsOf: profilesStore.url) == beforeBadProfile, "failed profile creation does not change disk")
do { _ = try profilesStore.editProfiles { try $0.renameSelected("   ") }; fatalError("blank names must be rejected") } catch {}
check(try Data(contentsOf: profilesStore.url) == beforeBadProfile, "failed rename leaves stored names intact")
let afterDelete = try profilesStore.editProfiles { try $0.deleteSelected() }
check(afterDelete.selectedID == "legacy.unassigned" && afterDelete.profiles.count == 3 && afterDelete.profiles.contains { $0.id == programmingID }, "deleting one mode keeps others and selects the preserved original")
let defaultReload = try MappingStore(directory: profilesStore.directory).load()
check(defaultReload.configuration == defaults && defaultReload.library.selectedID == "legacy.unassigned", "profile edits do not change original default keys")
// Deletion targets the picker choice, independently of the loaded mode.
_ = try profilesStore.editProfiles { try $0.select(programmingID) }
let activeBeforeInactiveDelete = try profilesStore.load().configuration
let inactiveDeleted = try profilesStore.editProfiles { try $0.delete(pptID) }
check(inactiveDeleted.selectedID == programmingID && inactiveDeleted.selected.configuration == activeBeforeInactiveDelete && !inactiveDeleted.profiles.contains { $0.id == pptID }, "deleting an unloaded choice keeps the active mode and all its keys")
let beforeProtectedDelete = try Data(contentsOf: profilesStore.url)
do { _ = try profilesStore.editProfiles { try $0.delete("default") }; fatalError("missing former placeholder cannot be deleted") } catch {}
do { _ = try profilesStore.editProfiles { try $0.delete(pptID) }; fatalError("a stale delete selection must fail") } catch {}
check(try Data(contentsOf: profilesStore.url) == beforeProtectedDelete, "protected or stale deletion leaves mode data and active selection intact")
_ = try profilesStore.editProfiles { try $0.delete(programmingID) }
let afterActiveDeleteRestart = try MappingStore(directory: profilesStore.directory).load()
check(afterActiveDeleteRestart.library.selectedID == "legacy.unassigned" && afterActiveDeleteRestart.configuration == defaults && afterActiveDeleteRestart.library.profiles.count == 1, "deleting the active choice loads Default and persists the fallback across restart")
do { _ = try profilesStore.editProfiles { try $0.deleteSelected() }; fatalError("last retained profile cannot be deleted") } catch {}
let wholeModeStore = MappingStore(directory:auditRoot.appendingPathComponent("whole-mode-load"))
_ = try wholeModeStore.load()
let dualMode = try wholeModeStore.editProfiles { library in
    try library.duplicate(name:"长按编程")
    let i = library.selectedIndex
    library.profiles[i].configuration.triggers[0x35] = .shortLong
    library.profiles[i].configuration.longBindings[0x35] = [0xE0,0xE1,0xE3,0x21]
    library.profiles[i].configuration.longPressDelay = 0.8
}
let ordinaryMode = try wholeModeStore.editProfiles { library in
    try library.duplicate(name:"播放器")
    library.profiles[library.selectedIndex].configuration = MappingConfiguration(bindings:[0x28:[0x2C]],repeatEnabled:false)
}
_ = try wholeModeStore.editProfiles { try $0.select(dualMode.selectedID) }
check(try MappingStore(directory:wholeModeStore.directory).load().configuration == dualMode.selected.configuration,"mode load restores both targets, behavior and threshold")
_ = try wholeModeStore.editProfiles { try $0.select(ordinaryMode.selectedID) }
check(try wholeModeStore.load().configuration == ordinaryMode.selected.configuration,"loading ordinary mode removes the previous mode's long targets")
_ = try wholeModeStore.editProfiles { try $0.delete(ordinaryMode.selectedID) }
check(try wholeModeStore.load().configuration == defaults,"active deletion restores complete default mode")
print("PASS: whole-mode short/long targets, timing, repeat options, load and delete fallback")
let oldDiagnostics = legacy.appendingPathComponent("Diagnostics")
try FileManager.default.createDirectory(at: oldDiagnostics, withIntermediateDirectories: true)
try Data("\"old-input\"".utf8).write(to: oldDiagnostics.appendingPathComponent("audio-input-restore.json"))
let newDiagnostics = migration.appendingPathComponent("Diagnostics")
try migrated.migrateRecoveryJournals(to: newDiagnostics)
try FileManager.default.removeItem(at: newDiagnostics.appendingPathComponent("audio-input-restore.json"))
try migrated.migrateRecoveryJournals(to: newDiagnostics)
check(!FileManager.default.fileExists(atPath: newDiagnostics.appendingPathComponent("audio-input-restore.json").path), "consumed recovery journal is not resurrected from legacy storage on relaunch")
print("PASS: profile duplication, independent keys, active-mode restart, rename/delete, invalid-name rollback, default retention and one-time recovery migration")

// Security regressions: no access to live input, Bluetooth or system audio.
let privateRoot = auditRoot.appendingPathComponent("private-files")
try PrivateFiles.ensureDirectory(privateRoot)
let privateFile = privateRoot.appendingPathComponent("settings.json")
try PrivateFiles.write(Data("original".utf8), to: privateFile)
func mode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
check(try mode(privateRoot) == 0o700 && mode(privateFile) == 0o600, "private directories and files have owner-only permissions")
let outside = auditRoot.appendingPathComponent("untouched.txt")
try Data("outside".utf8).write(to: outside)
let link = privateRoot.appendingPathComponent("linked.json")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
do { _ = try PrivateFiles.read(link); fatalError("must reject symlink reads") } catch {}
do { try PrivateFiles.write(Data("bad".utf8), to: link); fatalError("must reject symlink writes") } catch {}
check(try Data(contentsOf: outside) == Data("outside".utf8), "symlink target not changed")
let hardlink = privateRoot.appendingPathComponent("hardlink.json")
try FileManager.default.linkItem(at: outside, to: hardlink)
do { try PrivateFiles.protectFile(hardlink); fatalError("must reject shared inode chmod") } catch {}
do { _ = try PrivateFiles.read(hardlink); fatalError("must reject hardlink reads") } catch {}
do { try PrivateFiles.write(Data(), to: hardlink); fatalError("must reject hardlink writes") } catch {}
let dirLink = auditRoot.appendingPathComponent("directory-link")
try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: privateRoot)
do { try PrivateFiles.ensureDirectory(dirLink); fatalError("must reject linked private directory") } catch {}
let large = privateRoot.appendingPathComponent("oversized.json")
try Data(repeating: 1, count: 4097).write(to: large)
do { _ = try PrivateFiles.read(large, limit: 4096); fatalError("must reject oversized read") } catch {}
do { try PrivateFiles.write(Data(repeating: 1, count: 4097), to: privateFile, limit: 4096); fatalError("must reject oversized write") } catch {}
check(try PrivateFiles.read(privateFile) == Data("original".utf8), "rejected write preserves prior contents")
let lockDir = auditRoot.appendingPathComponent("lock-link")
try PrivateFiles.ensureDirectory(lockDir)
try FileManager.default.createSymbolicLink(at: lockDir.appendingPathComponent("instance.lock"), withDestinationURL: outside)
do { _ = try InstanceLease().acquire(in: lockDir); fatalError("must reject symlink instance lock") } catch {}
print("PASS: owner-only files, atomic failure preserves data, symlink/hardlink/linked-directory/lock rejection and bounded reads/writes")

var authorization = VoiceAuthorization()
check(!authorization.request(now: 1), "unsolicited BLE start cannot authorize audio")
check(!authorization.acceptPending(now: 1.1), "pending BLE start without physical press remains rejected")
authorization.reset()
check(authorization.press(), "first physical mic press observed")
check(authorization.request(now: 2), "physical press authorizes one BLE start")
check(!authorization.request(now: 2.1), "held mic cannot authorize another session after timeout or stop")
check(!authorization.press(), "repeated HID press does not refresh authorization")
authorization.release()
check(!authorization.held, "release stops permission to deliver audio")
check(!authorization.request(now: 3), "next BLE request can precede HID but cannot start audio")
check(authorization.press() && authorization.acceptPending(now: 3.1), "BLE-first ordering works within 300 ms of physical press")
check(!authorization.acceptPending(now: 3.2), "pending authorization consumed once")
authorization.release()
check(!authorization.request(now: 4), "defer another unsolicited start")
check(authorization.press() && !authorization.acceptPending(now: 4.5), "expired BLE start cannot be revived by a later press")
authorization.reset()
check(!authorization.held && !authorization.acceptPending(now: 5), "disconnect clears held and pending state")
check(RemoteHIDIdentity.make(transport: "USB", location: 1) == nil, "same vendor/product USB device is not accepted")
check(RemoteHIDIdentity.make(transport: "Bluetooth Low Energy", location: 0) == nil, "missing stable HID identity is rejected")
let trust = try RemoteBinding(peripheralID: UUID(), hidIdentity: "ble:829676884").validated()
let trustFile = privateRoot.appendingPathComponent("binding.json")
try PrivateFiles.write(JSONEncoder().encode(trust), to: trustFile, limit: 4096)
check(try JSONDecoder().decode(RemoteBinding.self, from: PrivateFiles.read(trustFile, limit: 4096)).validated() == trust, "device binding persists exactly")
do { _ = try RemoteBinding(peripheralID: UUID(), hidIdentity: "").validated(); fatalError("empty HID binding must fail") } catch {}
print("PASS: unsolicited audio rejected, HID-first/BLE-first ordering, replay/timeout/release/disconnect, stable device filtering and binding persistence")

let logDirectory = auditRoot.appendingPathComponent("log-bounds")
var diagnosticPolicy = DiagnosticsStore.Policy()
diagnosticPolicy.logFileBytes = 256; diagnosticPolicy.logTotalBytes = 768
diagnosticPolicy.recordingTotalBytes = 2000; diagnosticPolicy.maxAge = 60
diagnosticPolicy.linesPerSecond = 3
let logs = try DiagnosticsStore(directory: logDirectory, policy: diagnosticPolicy)
let now = Date()
check(try logs.append("first\nforged\rline\u{001B}", now: now)?.contains("\nforged") == false, "log content cannot inject a second log line")
_ = try logs.append("second", now: now); _ = try logs.append("third", now: now)
check(try logs.append("rate-limited", now: now) == nil, "diagnostic rate limit applies before disk/UI logging")
for i in 1...30 { _ = try logs.append(String(repeating: "x", count: 100), now: now.addingTimeInterval(Double(i))) }
try logs.prune(now: now.addingTimeInterval(31))
let logFiles = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }
let sizes = try logFiles.map { (try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as! NSNumber).intValue }
check(sizes.allSatisfy { $0 <= 256 } && sizes.reduce(0,+) <= 768, "log rotation enforces per-file and total sizes")
let oldLog = logDirectory.appendingPathComponent("session-old.log")
try PrivateFiles.write(Data("old".utf8), to: oldLog)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: oldLog.path)
let journal = logDirectory.appendingPathComponent("mapping-restore.json")
try PrivateFiles.write(Data("keep".utf8), to: journal)
try logs.prune(now: now)
check(!FileManager.default.fileExists(atPath: oldLog.path), "expired diagnostics removed")
check(try PrivateFiles.read(journal) == Data("keep".utf8), "retention never deletes mapping recovery journal")
let recording = try logs.saveRecording(wave: Data(repeating: 0, count: 100), compressed: Data([1]), metadata: Data("{}".utf8))
check(try mode(recording) == 0o600, "recorded audio is private")
try logs.removeRecordings()
check(!FileManager.default.fileExists(atPath: recording.path) && FileManager.default.fileExists(atPath: journal.path), "recording cleanup excludes recovery and settings")
print("PASS: diagnostic line sanitization, rate limit, file rotation, total quota, expiration, private recordings and scoped cleanup")

// v0.6: deterministic press-time tests never post input to the desktop.
do {
    let engine = RemoteActionEngine()
    var events: [String] = [], repeated: [UInt16] = []
    engine.emit = { events.append("\($0):\($1 ? "d" : "u")") }
    engine.repeatKey = { repeated.append($0) }
    let bindings: [UInt16:[UInt16]] = [0x35:[0xE2,0xE3,5],0xF1:[0x2A],0x3E:[0xE7],0x28:[0xE0,0x28]]
    let longs: [UInt16:[UInt16]] = [0x35:[0xE0,0xE1,0xE3,0x21],0xF1:[0x29]]
    func step(_ keys: Set<UInt16>, _ t: Double, modes: [UInt16:ActionTrigger] = [:], enabled: Bool = true) {
        engine.update(keys,bindings:bindings,repeatEnabled:enabled,triggers:modes,longBindings:longs,longPressDelay:0.6,now:t)
    }
    func reset() { engine.releaseAll(); events = []; repeated = [] }
    step([0x35],0); check(events == ["226:d","227:d","5:d"],"ordinary mapping starts immediately")
    engine.tick(now:100); check(repeated.isEmpty && events.count == 3,"ordinary hold never repeats or switches targets")
    step([],101); check(events.suffix(3) == ["5:u","227:u","226:u"],"ordinary target releases in reverse order")
    reset(); step([0xF1],0); engine.tick(now:0.399)
    check(events == ["42:d"] && repeated.isEmpty,"repeat gets immediate first press and waits before repeating")
    engine.tick(now:0.4); engine.tick(now:0.48)
    check(repeated == [0x2A,0x2A],"repeat starts at threshold and follows cadence")
    step([],0.5); engine.tick(now:4)
    check(events == ["42:d","42:u"] && repeated.count == 2,"release immediately stops repeating without final duplicate")
    let dual: [UInt16:ActionTrigger] = [0x35:.shortLong]
    reset(); step([0x35],0,modes:dual); engine.tick(now:0.599)
    check(events.isEmpty,"dual target never sends short before release")
    step([],0.599,modes:dual)
    check(events == ["226:d","227:d","5:d","5:u","227:u","226:u"],"release before threshold fires short only")
    reset(); step([0x35],0,modes:dual); engine.tick(now:0.6)
    check(events == ["224:d","225:d","227:d","33:d"],"long fires exactly at threshold")
    engine.tick(now:20); check(events.count == 4 && repeated.isEmpty,"long action starts once without repeat")
    step([],21,modes:dual)
    check(events == ["224:d","225:d","227:d","33:d","33:u","227:u","225:u","224:u"],"long release never appends short target")
    for releasedAt in [0.6,0.600001,8.0] {
        reset(); step([0x35],0,modes:dual); step([],releasedAt,modes:dual)
        check(events.count == 8 && events[0] == "224:d" && !events.contains("5:d"),"delayed/missing timer classifies boundary release as long once")
    }
    reset(); step([0x35],0,modes:dual,enabled:false); engine.tick(now:0.7); step([],0.8,modes:dual,enabled:false)
    check(events.count == 8,"global repeat toggle does not disable dual recognition")
    reset(); step([0xF1],0,enabled:false); engine.tick(now:4); step([],5,enabled:false)
    check(events == ["42:d","42:u"] && repeated.isEmpty,"disabled repeat retains ordinary first press/release")
    for source in ActionTrigger.repeatingSources {
        reset(); engine.update([source],bindings:[source:[0xE0,0x2A]],now:0)
        engine.tick(now:0.4); engine.tick(now:100); engine.update([],bindings:[:],now:101)
        check(events == ["224:d","42:d","42:u","224:u"] && repeated == [0x2A,0x2A],"all seven repeat sources retain modifiers and no timer catch-up burst")
    }
    reset(); step([0x3E],0); check(engine.microphoneHeld && events == ["231:d"],"mic down preserves immediate right Command and audio authorization")
    step([],1); check(!engine.microphoneHeld && events == ["231:d","231:u"],"mic up releases output and authorization")
    for heldTime in [0.2,0.7] {
        reset(); step([0x35],0,modes:dual); engine.tick(now:heldTime)
        engine.releaseAll(blocking:[0x35]); let before = events
        step([0x35],2,modes:dual); engine.tick(now:3); step([],4,modes:dual)
        check(events == before,"mode edit/disconnect cancellation neither retriggers long nor adds short")
        step([0x35],5,modes:dual); step([],5.1,modes:dual)
        check(events.suffix(6) == ["226:d","227:d","5:d","5:u","227:u","226:u"],"fresh press works after blocked key is released")
    }
    reset(); step([0x3E],0); engine.releaseAll(blocking:[0x3E])
    check(!engine.microphoneHeld,"cancelled held microphone cannot reauthorize until release and fresh press")
    step([],1)
    for target: UInt16 in 0xF101...0xF105 {
        reset(); engine.update([0x35],bindings:[0x35:[0x28]],triggers:dual,longBindings:[0x35:[0xE0,target]],now:0)
        engine.tick(now:0.6); engine.tick(now:8); engine.update([],bindings:[:],now:9)
        check(events == ["224:d","\(target):d","\(target):u","224:u"] && repeated.isEmpty,"long keyboard/mouse targets hold until release and never auto-click")
    }
    reset(); engine.update([0x35],bindings:[0x35:[]],triggers:dual,longBindings:[0x35:[0x29]],now:0)
    engine.update([],bindings:[:],now:0.2); check(events.isEmpty,"disabled short target is a valid long-only mapping")
    reset(); engine.update([0x35],bindings:[0x35:[0x28]],triggers:dual,now:0)
    engine.tick(now:1); engine.update([],bindings:[:],now:2); check(events.isEmpty,"unset long never falls back to short")
    reset(); engine.update([0x35],bindings:[0x35:[0xE0,4]],now:0)
    engine.update([0x35,0x28],bindings:[0x28:[0xE0,5]],now:0.1)
    engine.update([0x28],bindings:[:],now:0.2)
    check(!events.contains("224:u"),"shared output modifier remains down for its other owner")
    engine.update([],bindings:[:],now:0.3); check(events.last == "224:u","last owner releases modifier")
    reset(); engine.update([0x35],bindings:[0x35:[4]],triggers:dual,longBindings:[0x35:[5]],now:0)
    engine.update([0x35],bindings:[0x35:[6]],triggers:dual,longBindings:[0x35:[7]],now:0.3)
    engine.tick(now:0.6); engine.update([],bindings:[:],now:1)
    check(events == ["5:d","5:u"],"duplicate reports cannot reset timing or rewrite an active cycle's target")
    reset(); engine.emit = { usage, down in events.append("\(usage):\(down ? "d" : "u")"); if down { engine.releaseAll(blocking:[0x35]) } }
    engine.update([0x35],bindings:[0x35:[0xE0,4]],now:0)
    check(events == ["224:d","224:u"],"synchronous output failure cancels remaining downs and releases only sent keys")
    print("PASS: three modes, exact boundary/delayed timer, seven repeats, immediate mic, cancellation, mouse holds, output ownership and reentrant failure")
}

for mouse: UInt16 in 0xF101...0xF105 {
    var capture = ShortcutCapture(); _ = capture.modifiers([0xE0]); _ = capture.key(mouse,down:true); _ = capture.key(mouse,down:false)
    check(capture.modifiers([]) == .complete([0xE0,mouse]),"Ctrl plus mouse target records as one chord")
    for source in RemoteReport.names.keys {
        _ = try matrixStore.update(source:source,keys:[0xE0,mouse])
        check(try MappingStore(directory:matrixDirectory).load().configuration.bindings[source] == [0xE0,mouse],"each of 13 remote keys persists keyboard plus mouse targets")
    }
    let event = KeyboardEmitter.makeEvent(usage:mouse,down:true,flags:0x40001,source:nil,receipt:7)!
    check(event.flags.rawValue == 0x40001,"mouse target carries exact Control modifiers")
    if mouse <= 0xF103 {
        check(event.type == (mouse == 0xF101 ? .leftMouseDown : mouse == 0xF102 ? .rightMouseDown : .otherMouseDown),"correct mouse button down type")
        check(KeyboardEmitter.makeEvent(usage:mouse,down:false,flags:0x40001,source:nil,receipt:8)!.type == (mouse == 0xF101 ? .leftMouseUp : mouse == 0xF102 ? .rightMouseUp : .otherMouseUp),"correct mouse release type")
    } else {
        check(event.type == .scrollWheel && event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == (mouse == 0xF104 ? 3 : -3),"scroll direction and distance")
        check(KeyboardEmitter.makeEvent(usage:mouse,down:false,flags:0,source:nil,receipt:8) == nil,"scroll release generates no duplicate scroll")
    }
}
check(KeyboardEmitter.makeEvent(usage:0x2A,down:true,flags:0,source:nil,receipt:8,isRepeat:true)!.getIntegerValueField(.keyboardEventAutorepeat) == 1,"repeat event has real system autorepeat flag")
let triggerStore = MappingStore(directory:auditRoot.appendingPathComponent("v5-behavior-persistence"))
_ = try triggerStore.load()
for behavior in ActionTrigger.selectable {
    for source in RemoteReport.names.keys {
        _ = try triggerStore.editProfiles { $0.profiles[$0.selectedIndex].configuration.triggers[source] = behavior }
        _ = try triggerStore.updateLong(source:source,keys:[0xE0,0xF101])
        _ = try triggerStore.update(source:source,keys:[0xE2,0x28])
        let config = try MappingStore(directory:triggerStore.directory).load().configuration
        check(config.trigger(for:source) == behavior && config.longBindings[source] == [0xE0,0xF101] && config.bindings[source] == [0xE2,0x28],"all 13 rows persist each behavior and independent keyboard/mouse targets")
    }
}
let pressProfileID = try triggerStore.load().library.selectedID
let pressSnapshot = try triggerStore.adoptCurrentAsDefaultOnce().configuration
let otherMode = try triggerStore.editProfiles { try $0.duplicate(name:"独立长按"); $0.profiles[$0.selectedIndex].configuration.longPressDelay = 1.2 }
_ = try triggerStore.updateLong(source:0x35,keys:[0xE7])
check(try triggerStore.load().configuration.longBindings[0x35] == [0xE7],"editing long target persists")
_ = try triggerStore.editProfiles { try $0.select(pressProfileID) }
check(try triggerStore.load().configuration == pressSnapshot,"other mode does not overwrite the retained short/long snapshot")
_ = try triggerStore.editProfiles { try $0.select(otherMode.selectedID) }
check(try triggerStore.load().configuration.longPressDelay == 1.2,"long timing is part of each mode")
_ = try triggerStore.update(source:0x35,keys:nil)
check(try triggerStore.load().configuration.trigger(for:0x35) == .hold,"restore original cannot leave deferred long behavior bypassing suppression")
let beforeInvalid = try PrivateFiles.read(triggerStore.url)
for delay in [0.0,0.199,2.001,Double.infinity,Double.nan] {
    do { _ = try triggerStore.editProfiles { $0.profiles[$0.selectedIndex].configuration.longPressDelay = delay }; fatalError("invalid timing must reject") } catch {}
}
do { _ = try triggerStore.updateLong(source:0xFFFF,keys:[0x28]); fatalError("invalid source must reject") } catch {}
do { _ = try triggerStore.updateLong(source:0x35,keys:[0xFFFF]); fatalError("invalid long key must reject") } catch {}
do { _ = try triggerStore.updateLong(source:0x35,keys:[0xF101,0xF102]); fatalError("multiple mouse targets must reject") } catch {}
check(try PrivateFiles.read(triggerStore.url) == beforeInvalid,"invalid new-field edits preserve exact previous save")
check((try JSONSerialization.jsonObject(with:beforeInvalid) as! [String:Any])["version"] as? Int == 9,"gesture-aware touch fields use schema v9 so older apps cannot overwrite them")
for version in [2,3,4] {
    let migrationStore = MappingStore(directory:auditRoot.appendingPathComponent("legacy-v\(version)"))
    let original: [String:Any] = ["version":version,"selectedID":"custom","profiles":[
        ["id":"default","name":"默认","bindings":Dictionary(uniqueKeysWithValues:MappingConfiguration.defaultBindings.map{(String($0.key),$0.value.map(Int.init))})],
        ["id":"custom","name":"codex v1","bindings":Dictionary(uniqueKeysWithValues:MappingConfiguration.defaultBindings.map{(String($0.key),$0.value.map(Int.init))}),"triggers":["53":"release","128":"repeating"],"combinations":[["id":"legacy-tv-menu","sources":[53,101],"keys":[224,225,227,33],"leader":53,"trigger":"hold"]]]]]
    let bytes = try JSONSerialization.data(withJSONObject:original,options:[.sortedKeys])
    try PrivateFiles.write(bytes,to:migrationStore.url)
    let loaded = try migrationStore.load()
    check(loaded.library.selectedID == "custom" && loaded.library.profiles.count == 2 && loaded.configuration.bindings == MappingConfiguration.defaultBindings,"legacy migration preserves selection, profiles and all current single mappings")
    check(loaded.configuration.combinations.isEmpty && loaded.configuration.trigger(for:0x35) == .hold && loaded.configuration.longBindings.isEmpty,"legacy guide exits runtime without silently converting its target")
    check(try PrivateFiles.read(migrationStore.migrationBackupURL) == bytes,"full original document archived byte for byte before migration")
    _ = try migrationStore.updateLong(source:0x35,keys:[0xE7]); _ = try migrationStore.updateLong(source:0x35,keys:[0xE0,0x28])
    check(try PrivateFiles.read(migrationStore.migrationBackupURL) == bytes,"rolling saves never replace the pre-upgrade archive")
    check(try MappingStore(directory:migrationStore.directory).load().configuration.longBindings[0x35] == [0xE0,0x28],"later restarts do not rerun migration over new long targets")
}
print("PASS: 13 × three behaviors, independent short/long mouse targets, schema v9, modes, retained snapshot, validation rollback and v2/v3/v4 archived migration")

// Branding must not invalidate an existing physical-device binding.
let legacyBindingData = Data("{\"version\":1,\"peripheralID\":\"5A6869E7-DBA0-4B6A-A630-5178526F381D\",\"hidIdentity\":\"ble:1234\"}".utf8)
let legacyBinding = try JSONDecoder().decode(RemoteBinding.self,from:legacyBindingData).validated()
check(legacyBinding.model == .xiaomi && legacyBinding.deviceName == nil,"legacy bindings retain Xiaomi model and exact device identity")
let namedBinding = try RemoteBinding(peripheralID:legacyBinding.peripheralID,hidIdentity:legacyBinding.hidIdentity,modelID:RemoteModel.xiaomi.id,deviceName:"Mi RC").validated()
check(try JSONDecoder().decode(RemoteBinding.self,from:JSONEncoder().encode(namedBinding)).validated() == namedBinding,"named device identity persists without changing trust target")
for model in ["apple-siri-remote","untrusted-model"] {
    do { _ = try RemoteBinding(peripheralID:UUID(),hidIdentity:"ble:12",modelID:model).validated(); fatalError("unsupported devices cannot be silently trusted") } catch {}
}
func connectionState(bound:Bool=true,paused:Bool=false,present:Bool=true,radio:RemoteRadio = .ready,input:Bool=true,output:Bool=true,mapping:Bool=true,mic:Bool=true,voice:Bool=true,driver:Bool=true,failure:String? = nil,pairingChanged:Bool=false) -> RemoteDeviceStatus {
    RemoteDeviceStatus.resolve(bound:bound,stopped:paused,present:present,radio:radio,inputAllowed:input,outputAllowed:output,mappingReady:mapping,microphoneEnabled:mic,voiceReady:voice,driverAvailable:driver,outputFailure:failure,pairingChanged:pairingChanged)
}
check(connectionState().connection == .connected && connectionState().microphone == "已就绪","ready input and microphone are independently visible")
let lost = connectionState(present:false,voice:false)
check(lost.connection == .disconnected && lost.keyboard == "等待连接" && lost.microphone == "等待连接","disconnect immediately clears both input-ready labels")
let microphoneDenied = connectionState(radio:.unauthorized,voice:false)
check(microphoneDenied.connection == .connected && microphoneDenied.keyboard == "已就绪" && microphoneDenied.microphone == "需要蓝牙权限","audio permission failure does not conceal working keyboard connection")
let monitorDenied = connectionState(input:false,mapping:false)
check(monitorDenied.connection == .connected && monitorDenied.keyboard == "需要输入监控权限" && monitorDenied.microphone == "已就绪","missing input permission is not reported as remote disconnection")
check(connectionState(output:false,mapping:false).keyboard == "需要辅助功能权限","output permission has a distinct status")
check(connectionState(present:false,radio:.off).connection == .bluetoothOff,"Bluetooth off is explicit")
check(connectionState(present:false,radio:.unauthorized).connection == .permission,"unknown link with missing Bluetooth permission is not a fake disconnect")
check(connectionState(present:false,radio:.checking).connection == .checking,"initial discovery remains checking")
check(connectionState(bound:false).connection == .unselected,"no binding never displays a manufacturer as connected")
check(connectionState(paused:true).connection == .paused,"user pause never displays live service readiness")
check(connectionState(mic:false).microphone == "已关闭","microphone toggle affects audio only")
check(connectionState(driver:false).microphone == "需要安装麦克风组件","missing audio component is distinct from BLE connection")
check(connectionState().connection == .connected,"reconnection restores a ready presentation from fresh signals")
check(connectionState(mapping:false,failure:"通道暂停").keyboard == "发送异常，请重新检测" && connectionState(failure:"通道暂停").hint == "通道暂停", "real output failure is actionable instead of preparing forever")
check(connectionState(pairingChanged:true).microphone == "需重新选择设备" && connectionState(pairingChanged:true).hint.contains("已有键位和模式会保留"), "re-pairing explains device selection and preserves mappings")
print("PASS: device status, disconnected/permissions/audio independence, legacy binding migration and unsupported model rejection")

// TV short/long report pipeline: no second remote key is required.
do {
    let original = MappingConfiguration(triggers:[0x35:.shortLong],longBindings:[0x35:[0xE0,0xE1,0xE3,0x21]])
    let config = try JSONDecoder().decode(MappingConfiguration.self,from:JSONEncoder().encode(original)).validated()
    let plan = MappingPlan(configuration:config), engine = RemoteActionEngine()
    var emitted: [(UInt16,Bool)] = []
    engine.emit = { emitted.append(($0,$1)) }
    func report(_ bytes:[UInt8], _ time:TimeInterval) {
        engine.update(RemoteReport.parse(id:1,data:Data(bytes))!,bindings:plan.software,triggers:config.triggers,longBindings:plan.longPress,longPressDelay:config.longPressDelay,now:time)
    }
    report([0x35,0,0,0,0,0],0); engine.tick(now:0.6); report([0,0,0,0,0,0],1)
    check(emitted.map{$0.0} == [0xE0,0xE1,0xE3,0x21,0x21,0xE3,0xE1,0xE0],"one TV key's held report sends the long screenshot chord without any Menu report")
    let event = KeyboardEmitter.makeEvent(usage:0x21,down:true,flags:CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue,source:nil,receipt:501)!
    check(event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 21 && event.flags.contains([.maskControl,.maskShift,.maskCommand]),"screenshot target retains exact key code and modifiers")
    let onlyLong = MappingPlan(configuration:MappingConfiguration(bindings:[0x35:[]],triggers:[0x35:.shortLong],longBindings:[0x35:[0xE7]]))
    check(onlyLong.native[0x35] == 0 && onlyLong.software.isEmpty && onlyLong.longPress[0x35] == [0xE7],"long-only mapping still suppresses native key and requires output permissions")
    print("PASS: saved TV short/long mapping through HID parser, output plan, delayed action and native event construction")
}

do {
    var battery = RemoteBatteryReading(); let date = Date(timeIntervalSince1970:1000)
    check(battery.current(connected:true,now:date) == nil,"missing battery never displays zero")
    for value in [0,1,20,21,50,72,100] {
        check(battery.receive(Data([UInt8(value)]),now:date),"valid battery percentage accepted")
        check(battery.current(connected:true,now:date) == value,"battery percentage retained exactly")
        check(battery.title(connected:true,now:date).contains("电量低") == (value <= 20),"low battery threshold includes zero and twenty")
    }
    for bytes: [UInt8] in [[],[101],[255],[72,0]] { check(!battery.receive(Data(bytes),now:date),"malformed battery payload rejected") }
    check(battery.current(connected:false,now:date) == nil && battery.title(connected:false,now:date).contains("未连接"),"disconnect hides cached percentage")
    check(battery.current(connected:true,now:date.addingTimeInterval(661)) == nil,"stale data is not represented as live battery")
    check(battery.current(connected:true,now:date.addingTimeInterval(-1)) == nil,"clock rollback does not make stale data fresh")
    check(RemoteBatteryReading.symbol(for:0) == "battery.0percent" && RemoteBatteryReading.symbol(for:100) == "battery.100percent","battery icon includes empty and full bounds")
    print("PASS: battery payload bounds, unknown vs zero, low threshold, disconnect and stale data")
}

// v0.7: built-ins use an independent, committed snapshot, never a user's home.
var fixtureProfile = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/codex-preset-v1.json"))) as! [String:Any]
fixtureProfile["id"] = "default"; fixtureProfile["name"] = "默认"
let fixtureStore = MappingStore(directory:auditRoot.appendingPathComponent("independent-codex-fixture"))
try PrivateFiles.write(JSONSerialization.data(withJSONObject:["version":5,"selectedID":"default","profiles":[fixtureProfile]]),to:fixtureStore.url)
let codexFixture = try fixtureStore.load().configuration
check(BuiltInPreset.codex.configuration == codexFixture,"factory Codex exactly matches the accepted active layout, including all long actions")
for preset in BuiltInPreset.allCases {
    _ = try preset.configuration.validated()
    let model: RemoteModel = [.appleCodex,.applePPT].contains(preset) ? .apple : .xiaomi
    check(Set(preset.configuration.bindings.keys) == Set(RemoteButtonLayout.rows(for:model)),"built-in covers every supported button of its own model")
}
let freshAppStore = MappingStore(directory:auditRoot.appendingPathComponent("fresh-v070"))
let freshApp = try freshAppStore.loadForApp()
check(freshApp.library.selectedID == BuiltInPreset.codex.id && freshApp.library.profiles.count == 4 && freshApp.library.unassignedProfiles.isEmpty,"clean install starts with Codex and four model-owned presets without a placeholder")
check(freshApp.library.profile(id:BuiltInPreset.codex.id,for:RemoteModel.xiaomi.id)?.configuration == codexFixture,"clean Xiaomi Codex has the complete accepted long/short preset")
check(!FileManager.default.fileExists(atPath:freshAppStore.directory.appendingPathComponent("遥控器绑定.json").path),"fresh presets create no device binding")
_ = try freshAppStore.updateLong(source:0x35,keys:[0x29])
let customFactoryCopy = try freshAppStore.loadForApp()
check(customFactoryCopy.configuration.longBindings[0x35] == [0x29] && BuiltInPreset.codex.configuration == codexFixture,"editing the loaded factory copy persists without changing the template")
let replacedCopy = try freshAppStore.editProfiles { try $0.addBuiltIn(.codex,selecting:true) }
check(replacedCopy.selected.configuration == codexFixture && replacedCopy.profiles.first { $0.id == BuiltInPreset.codex.id }!.configuration.longBindings[0x35] == [0x29],"adding a factory template creates a new copy and retains previous edits")
_ = try freshAppStore.editProfiles { try $0.delete(BuiltInPreset.ppt.id) }
check(try !freshAppStore.loadForApp().library.profiles.contains { $0.id == BuiltInPreset.ppt.id },"deleted factory copy is not silently resurrected on relaunch")

let upgradeStore = MappingStore(directory:auditRoot.appendingPathComponent("upgrade-v070"))
try upgradeStore.save(MappingConfiguration(bindings:[0x28:[0xE0,0x28]],triggers:[0x28:.shortLong],longBindings:[0x28:[0xE6,0x28]],longPressDelay:1.2))
_ = try upgradeStore.editProfiles { try $0.duplicate(name:"Codex") }
_ = try upgradeStore.editProfiles { try $0.duplicate(name:"PPT") }
let beforePresetUpgrade = try upgradeStore.load().library
let afterPresetUpgrade = try upgradeStore.loadForApp().library
check(Array(afterPresetUpgrade.profiles.prefix(beforePresetUpgrade.profiles.count)) == beforePresetUpgrade.profiles && afterPresetUpgrade.selectedID == beforePresetUpgrade.selectedID,"adding built-ins preserves every existing profile and selection exactly")
check(afterPresetUpgrade.profiles.count == 7 && RemoteModel.catalog.filter(\.supported).allSatisfy { model in let names=afterPresetUpgrade.profiles(for:model.id).map { $0.name.lowercased() }; return names.count == Set(names).count },"preset names remain unambiguous within each remote model")
check(try upgradeStore.loadForApp().library == afterPresetUpgrade,"factory installation is idempotent across restarts")
let pptPreset = BuiltInPreset.ppt.configuration
check(pptPreset.bindings[0x66] == [0xE3,0x28] && pptPreset.bindings[0x35] == [0xE1,0xE3,0x28] && pptPreset.bindings[0xF1] == [0x29],"PPT has Mac current/beginning slideshow and Escape")
check(!pptPreset.repeatEnabled && RemoteReport.names.keys.allSatisfy { pptPreset.trigger(for:$0) == .hold },"PPT does not repeatedly advance or exit while a button is held")
print("PASS: built-in Codex snapshot, Mac PPT, clean install, per-model names, editable copies, retained legacy profiles, deletion and upgrade persistence")

check(RemoteBindingReadiness.resolve(radio:.checking,inputAllowed:false,bluetoothCount:0,hidCount:0) == .checking,"uninitialized Bluetooth is not reported as no remote")
check(RemoteBindingReadiness.resolve(radio:.off,inputAllowed:true,bluetoothCount:1,hidCount:1) == .bluetoothOff,"Bluetooth off prevents binding")
check(RemoteBindingReadiness.resolve(radio:.unauthorized,inputAllowed:true,bluetoothCount:1,hidCount:1) == .bluetoothDenied,"Bluetooth denial gets a distinct recovery action")
check(RemoteBindingReadiness.resolve(radio:.ready,inputAllowed:false,bluetoothCount:1,hidCount:1) == .inputPermission,"unbound first install requests input permission before binding")
check(RemoteBindingReadiness.resolve(radio:.ready,inputAllowed:true,bluetoothCount:0,hidCount:0) == .noDevice,"unpaired first install asks for system pairing")
check(RemoteBindingReadiness.resolve(radio:.ready,inputAllowed:true,bluetoothCount:2,hidCount:1) == .multipleDevices,"two audio candidates cannot be bound to one unrelated HID identity")
check(RemoteBindingReadiness.resolve(radio:.ready,inputAllowed:true,bluetoothCount:1,hidCount:2) == .multipleDevices,"multiple keyboard devices require disambiguation")
check(RemoteBindingReadiness.resolve(radio:.ready,inputAllowed:true,bluetoothCount:1,hidCount:0) == .noDevice,"audio-only candidate cannot create partial binding")
check(RemoteBindingReadiness.resolve(radio:.ready,inputAllowed:true,bluetoothCount:1,hidCount:1) == .ready,"pairing plus permission plus one matching model reaches binding")
print("PASS: first-run pairing/permission/binding readiness, radio failures and ambiguous device protection")

do {
    let channel = ConsumingKeyboardChannel()
    var checks: [() -> Void] = []
    let emitter = KeyboardEmitter(channel:channel,scheduleReceiptCheck:{ checks.append($0) })
    func expire() { let pending = checks; checks = []; pending.forEach { $0() } }
    check(emitter.start() && !emitter.isObserving && channel.starts == 0 && channel.snapshotReads == 0,"ready output does not install a global listener or sample keyboard when idle")
    emitter.send(0x28,down:true)
    check(emitter.isObserving && channel.snapshotRequests == [Set<UInt16>(0xE0...0xE7).union([0x28])],"first action samples only its target and modifier states")
    let unrelated = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
    _ = channel.receiver?(.keyDown,unrelated)
    let before = channel.events.count
    emitter.send(0x04,down:true)
    check(channel.events.count == before + 1,"unrelated keyboard key was not retained as physical state")
    emitter.send(0x04,down:false); emitter.send(0x28,down:false); expire()
    check(!emitter.isObserving && emitter.isRunning && channel.receiver == nil,"release timeout closes observer even when all self-observations are consumed")
    channel.snapshot = [0xE0]
    emitter.send(0xE0,down:true)
    let beforeShared = channel.events.count
    emitter.send(0x28,down:true); emitter.send(0x28,down:false); emitter.send(0xE0,down:false); expire()
    check(channel.events.count == beforeShared + 2 && channel.events.last!.flags.contains(.maskControl),"releasing virtual Control preserves physically held Control")
    check(!emitter.isObserving,"shared physical ownership does not leave the observer running")
    channel.snapshot = []
    emitter.send(0xF101,down:true)
    let moved = CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:CGPoint(x:10,y:20),mouseButton:.left)!
    _ = channel.receiver?(.mouseMoved,moved)
    check(moved.type == .leftMouseDragged,"held remote mouse still converts physical pointer motion to dragging")
    let premature = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:.zero,mouseButton:.left)!
    check(channel.receiver?(.leftMouseUp,premature) == nil,"physical mouse release cannot cancel a held remote drag")
    emitter.send(0xF101,down:false); expire()
    check(!emitter.isObserving && channel.events.last!.type == .leftMouseUp,"remote mouse release ends dragging and shuts observation down")
    channel.observesPosts = true
    emitter.send(0xE7,down:true); emitter.send(0xE7,down:false)
    RunLoop.main.run(until:Date().addingTimeInterval(0.01))
    check(!emitter.isObserving,"visible releases shut observer without waiting for the timeout")
    emitter.send(0xE7,down:true); expire()
    check(emitter.isObserving,"old release cleanup cannot close a subsequent held voice action")
    emitter.send(0xE7,down:false); emitter.stop(); expire()
    check(!emitter.isObserving && !emitter.isRunning,"stop cancels delayed cleanup and all listeners")
}
let enterMask = KeyboardObservation.mask(for:[0x28])
check(enterMask & (1 << CGEventType.mouseMoved.rawValue) == 0 && enterMask & (1 << CGEventType.scrollWheel.rawValue) == 0,"keyboard-only output never subscribes to pointer motion or scroll")
check(KeyboardObservation.mask(for:[0xF101]) & (1 << CGEventType.mouseMoved.rawValue) != 0,"drag output subscribes to required movement")
check(KeyboardObservation.mask(for:[]) == 0,"empty scope has no global event types")
print("PASS: no idle global listener, targeted state snapshots, unrelated-key discard, bounded release cleanup, shared modifiers and mouse dragging")
do {
    let channel = ConsumingKeyboardChannel()
    var now: TimeInterval = 10
    var checks: [() -> Void] = []
    let emitter = KeyboardEmitter(channel:channel,scheduleReceiptCheck:{ checks.append($0) },clock:{ now })
    channel.snapshot = [0xE0]
    _ = emitter.start(); emitter.send(0x28,down:true); emitter.send(0x28,down:false)
    emitter.recover(); _ = emitter.start()
    now += 2; channel.snapshot = []
    emitter.send(0x28,down:true)
    check(!channel.events.last!.flags.contains(.maskControl),"a delayed post-recovery press refreshes physical modifiers released while idle")
    emitter.send(0x28,down:false); emitter.stop()
}
print("PASS: recovery snapshot expires; delayed reconnect does not retain an old physical modifier")

// Connection evidence is separate from a saved identity. No timer-only retries.
do {
    var policy = RemoteConnectionPolicy()
    for _ in 0..<120 {
        check(!policy.shouldAttach(hidConnected:false,systemConnected:false,pairingInvalid:false),"saved UUID alone must never attach")
        check(!policy.shouldAttach(hidConnected:true,systemConnected:false,pairingInvalid:false),"stale HID alone must never attach")
    }
    check(policy.shouldAttach(hidConnected:true,systemConnected:true,pairingInvalid:false),"one attach for an established system connection")
    for _ in 0..<120 { check(!policy.shouldAttach(hidConnected:true,systemConnected:true,pairingInvalid:false),"failed attach cannot repeat on a timer") }
    check(!policy.shouldAttach(hidConnected:false,systemConnected:true,pairingInvalid:false),"disconnect must wait")
    check(policy.shouldAttach(hidConnected:true,systemConnected:true,pairingInvalid:false),"fresh system reconnect can recover")
    _ = policy.shouldAttach(hidConnected:false,systemConnected:false,pairingInvalid:true)
    for _ in 0..<120 { check(!policy.shouldAttach(hidConnected:true,systemConnected:true,pairingInvalid:true),"pairing removal stays blocked") }
}
print("PASS: reconnect policy rejects cache-only/stale-HID/repeated attach, permits observed reconnect, blocks invalid pairing")

do {
    let directory = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("yaoban-devices-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at:directory) }
    let presets = MappingStore(directory:directory)
    var profiles = try presets.loadForApp().library
    let devices = RemoteDeviceStore(directory:directory), legacy = directory.appendingPathComponent("遥控器绑定.json")
    let fresh = try devices.load(migrating:legacy,profiles:profiles)
    check(fresh.devices.isEmpty && fresh.selectedID == nil,"clean install has no device")
    check(profiles.profiles.contains { $0.name == "Codex" } && profiles.profiles.contains { $0.name == "PPT" },"presets exist without hardware")
    // A distinct directory models an upgrade, with a byte-for-byte preserved legacy file.
    let upgrade = directory.appendingPathComponent("upgrade"), upgradeStore = RemoteDeviceStore(directory:upgrade)
    let legacyUpgrade = upgrade.appendingPathComponent("遥控器绑定.json")
    let binding = RemoteBinding(peripheralID:UUID(),hidIdentity:"ble:100",modelID:RemoteModel.xiaomi.id,deviceName:"Mi RC")
    let oldBytes = try JSONEncoder().encode(binding); try PrivateFiles.write(oldBytes,to:legacyUpgrade)
    var saved = try upgradeStore.load(migrating:legacyUpgrade,profiles:profiles)
    check(saved.devices.count == 1 && saved.selected?.configuration == profiles.selected.configuration,"upgrade retains complete selected short/long config")
    check(try PrivateFiles.read(legacyUpgrade) == oldBytes,"upgrade preserves legacy binding for rollback")
    saved.devices[0].configuration.touch = .init(mode:.pointer,speed:1.4)
    let first = saved.devices[0], firstID = first.id
    var second = first; second.id = UUID(); second.name = "second"; second.binding = RemoteBinding(peripheralID:UUID(),hidIdentity:"ble:200"); second.profileID = BuiltInPreset.codex.id; second.startupProfileID = BuiltInPreset.codex.id
    saved.devices.append(second); saved.selectDevice(second.id)
    saved.devices[1].configuration.bindings[0x28] = [0xE0,0x28]
    saved.devices[1].configuration.longBindings[0x35] = [0xE0,0x21]
    try upgradeStore.save(saved)
    check(saved.devices[0].configuration == first.configuration,"editing another device does not mutate first snapshot")
    check(try upgradeStore.load(migrating:legacyUpgrade,profiles:profiles) == saved,"device selection and both complete snapshots survive reopen")
    let preserved = try PrivateFiles.read(upgradeStore.url)
    check((try JSONSerialization.jsonObject(with:preserved) as! [String:Any])["version"] as? Int == 4,"gesture-aware device schema protects against old-app overwrite")
    var duplicate = saved; duplicate.devices[1].binding = first.binding
    do { try upgradeStore.save(duplicate); fatalError("duplicate physical identity accepted") } catch {}
    check(try PrivateFiles.read(upgradeStore.url) == preserved,"duplicate add fails without altering saved devices")
    try saved.remove(firstID); try upgradeStore.save(saved)
    check(saved.selectedID == second.id && saved.retained.first?.configuration == first.configuration,"delete retains last keys and another active selection")
    try saved.remove(second.id); try upgradeStore.save(saved)
    check(try upgradeStore.load(migrating:legacyUpgrade,profiles:profiles).devices.isEmpty,"deleting last device survives restart despite legacy binding")
    check(saved.retained.count == 2,"last configurations retained independently of templates")
    let restored = SavedRemote(name:"replacement",binding:RemoteBinding(peripheralID:UUID(),hidIdentity:"ble:300"),profileID:profiles.selectedID,configuration:saved.retained[0].configuration)
    saved.devices = [restored]; saved.selectedID = restored.id; try upgradeStore.save(saved)
    let replacementSnapshot = saved.devices[0].configuration
    saved.devices[0].binding = RemoteBinding(peripheralID:UUID(),hidIdentity:"ble:301")
    try upgradeStore.save(saved)
    check(saved.devices[0].configuration == replacementSnapshot,"re-pair changes identity without losing keys")
    var corrupt = saved; corrupt.version = 999
    try PrivateFiles.write(JSONEncoder().encode(corrupt),to:upgradeStore.url)
    do { _ = try upgradeStore.load(migrating:legacyUpgrade,profiles:profiles); fatalError("future device schema accepted") } catch {}
    check(try JSONDecoder().decode(RemoteDeviceLibrary.self,from:PrivateFiles.read(upgradeStore.url)).version == 999,"future device file remains untouched")

    // Saving a mode and deleting a used mode update device snapshots transactionally.
    try profiles.duplicate(name:"temporary mode")
    let customID = profiles.selectedID
    var state = RemoteDeviceLibrary()
    var active = first; active.profileID = customID
    state.devices = [active,second]; state.selectDevice(firstID)
    try DevicePresetTransaction.commit(profiles:profiles,devices:state,store:presets,deviceStore:devices)
    let beforeTemplateEdit = state.devices[0].configuration
    profiles.profiles[profiles.selectedIndex].configuration.bindings[0x28] = [0x2C]
    try DevicePresetTransaction.commit(profiles:profiles,devices:state,store:presets,deviceStore:devices)
    check(try devices.load(migrating:legacy,profiles:profiles).devices[0].configuration == beforeTemplateEdit,"saved template changes do not mutate loaded device copies")
    try profiles.delete(customID); state.reconcileProfiles(profiles,removedProfileIDs:[customID])
    check(state.devices[0].profileID == BuiltInPreset.codex.id && state.devices[0].configuration == profiles.profile(id:BuiltInPreset.codex.id,for:RemoteModel.xiaomi.id)!.configuration,"delete used preset loads the device startup preset")
    check(state.devices[1].configuration == second.configuration,"delete mode does not alter unrelated active device")
    // Simulate exit after only the preset file is written, then recover forward.
    let intent = DevicePresetTransaction(version:1,profiles:profiles,devices:state)
    try PrivateFiles.write(JSONEncoder().encode(intent),to:DevicePresetTransaction.url(presets))
    try presets.saveLibrary(profiles)
    try DevicePresetTransaction.recover(store:presets,deviceStore:devices)
    check(try devices.load(migrating:legacy,profiles:profiles) == state,"interrupted two-file save recovers device state")
    check(!FileManager.default.fileExists(atPath:DevicePresetTransaction.url(presets).path),"completed transaction leaves no pending intent")
    check(try presets.load().library == profiles,"transaction recovered matching preset library")
}
print("PASS: empty install, legacy migration, two independent devices, reload, duplicate rejection, delete/retain/restore/re-pair, template isolation and crash-recovered preset deletion")

do {
    let outputs = RemoteOutputOwnership(), voice = RemoteVoiceOwnership()
    let a = UUID(), b = UUID(), engineA = RemoteActionEngine(), engineB = RemoteActionEngine()
    var events: [String] = []
    outputs.emit = { events.append("\($0):\($1)") }
    engineA.emit = { outputs.send(owner:a,key:$0,down:$1) }; engineB.emit = { outputs.send(owner:b,key:$0,down:$1) }
    let mapping: [UInt16:[UInt16]] = [0x28:[0xE0,0xF101]]
    engineA.update([0x28],bindings:mapping,now:0); engineB.update([0x28],bindings:mapping,now:0)
    check(events == ["224:true","61697:true"],"two devices holding same modifier and mouse emit one down")
    engineA.releaseAll(); outputs.release(a)
    check(events.count == 2,"delete A cannot release B's modifier or mouse")
    engineB.update([],bindings:mapping,now:1)
    check(events == ["224:true","61697:true","61697:false","224:false"],"last owner releases mouse then modifier")
    check(voice.acquire(a) && !voice.acquire(b),"another device cannot steal current voice")
    check(!voice.release(b) && voice.owner == a,"non-owner release cannot end current microphone")
    check(voice.release(a) && voice.acquire(b),"next voice source acquires after release")
}
print("PASS: two device engines share modifiers/mouse without premature release; microphone ownership excludes competing devices")

do {
    check(AppleRemoteDesign.all.count == 3,"three Apple generations have independent catalog entries")
    check(AppleRemoteDesign.all.allSatisfy { !$0.hardwareVerified && $0.canActivate == ($0.model == .apple) && $0.model.supported == ($0.model == .apple) },"only verified Gen-3 button adapter can activate; complete hardware capability remains unverified")
    check(Set(AppleRemoteDesign.all.map { $0.model.id }).count == 3,"each generation has a distinct model identity")
    let first = AppleRemoteDesign.all.first { $0.model == .appleFirst }!, modern = AppleRemoteDesign.all.first { $0.model == .apple }!
    check(!first.buttons.contains { $0.id == "up" } && !first.buttons.contains { $0.id == "power" },"first gen does not invent physical directional or power buttons")
    check(modern.buttons.contains { $0.id == "siri" } && modern.buttons.contains { $0.id == "mute" },"modern layout includes side Siri and mute")
    check(AppleRemoteDesign.all.allSatisfy { $0.capabilitySummary.contains("麦克风：待适配") },"voice capability remains separate from button mapping")
}
print("PASS: Apple generation-specific button plans, capability gating and unverified hardware disclosure")

do {
    let appleID = AppleRemoteIdentity.make(serial:"fixture-only-A2854",location:123,transport:"Bluetooth Low Energy")!
    check(AppleRemoteIdentity.valid(appleID),"stable Apple identity is valid")
    check(AppleRemoteIdentity.make(serial:"fixture-only-A2854",location:456,transport:"Bluetooth Low Energy") == appleID,"serial-backed identity survives changed HID location")
    check(!AppleRemoteIdentity.valid("apple3:short") && !AppleRemoteIdentity.valid("apple3loc:0") && !AppleRemoteIdentity.valid("apple3loc:001"),"malformed Apple identities are rejected")
    check(AppleRemoteIdentity.make(serial:"",location:123,transport:"Bluetooth") == "apple3loc:123","missing serial uses explicit re-association identity")
    let binding = try RemoteBinding(peripheralID:nil,hidIdentity:appleID,modelID:RemoteModel.apple.id).validated()
    let x = SavedRemote(name:"Xiaomi",binding:legacyBinding,profileID:BuiltInPreset.codex.id,configuration:BuiltInPreset.codex.configuration)
    let a = SavedRemote(name:"Apple",binding:binding,profileID:BuiltInPreset.appleCodex.id,configuration:BuiltInPreset.appleCodex.configuration)
    var devices = RemoteDeviceLibrary(); devices.devices = [x,a]; devices.selectDevice(x.id)
    check(devices.activeID == x.id && devices.devices.filter(\.enabled).count == 1,"one active device initially")
    devices.selectDevice(a.id)
    check(devices.activeID == a.id && !devices.devices[0].enabled && devices.devices[1].enabled,"switch stops original device")
    check(devices.devices[0].configuration == x.configuration && devices.devices[1].configuration == a.configuration,"switch preserves both complete layouts")
    let selected = devices; devices.selectDevice(UUID()); check(devices == selected,"unknown selection cannot activate a device")
    let folder = auditRoot.appendingPathComponent("apple-switch")
    let store = RemoteDeviceStore(directory:folder); try store.save(devices)
    let reopened = try store.load(migrating:folder.appendingPathComponent("none.json"),profiles:MappingLibrary())
    check(reopened == devices,"selected Apple with no BLE UUID survives restart")
    var old = devices; old.devices[0].enabled = true
    try store.save(old)
    let normalized = try store.load(migrating:folder.appendingPathComponent("none.json"),profiles:MappingLibrary())
    check(normalized == devices,"old concurrent activation normalizes to current selection without losing keys")
    check(try JSONDecoder().decode(RemoteBinding.self,from:JSONEncoder().encode(binding)).validated() == binding,"Apple trust target round trips without invented BLE identity")
    for preset in [BuiltInPreset.appleCodex,.applePPT] {
        let config = try preset.configuration.validated()
        check(Set(config.bindings.keys) == Set(RemoteButtonLayout.appleRows),"Apple preset covers exactly supported physical keys")
        check(config.bindings[0x66] == nil && config.bindings[0x65] == nil && config.bindings[0x4A] == nil,"Apple preset does not expose power or imaginary menu/home buttons")
        check(RemoteButtonLayout.configuration(config,for:.xiaomi).bindings[RemoteButtonLayout.playPause] == nil,"Apple-specific sources cannot reach Xiaomi native mapping")
    }
    check(RemoteButtonLayout.source(.power) == nil,"power never enters software output")
    var outputs: [(UInt16,Bool)] = []
    let engine = RemoteActionEngine(); engine.emit = { outputs.append(($0,$1)) }
    engine.update([0x35],bindings:[0x35:[0x28]],triggers:[0x35:.shortLong],longBindings:[0x35:[0xE3,0x21]],now:10)
    engine.releaseAll(); engine.tick(now:12)
    check(outputs.isEmpty,"switch during a pending long press doesn't execute short or long")
    engine.update([0xF1],bindings:[0xF1:[0x2A]],now:20)
    check(outputs.contains { $0.0 == 0x2A && $0.1 },"repeat began before switching")
    engine.releaseAll(); let atSwitch = outputs.count; engine.tick(now:30)
    check(outputs.count == atSwitch && outputs.last?.0 == 0x2A && outputs.last?.1 == false,"switch releases repeating key and cancels timer")
}
print("PASS: single active remote, Apple trust identity, per-device presets, restart, and switch cancels held/long/repeat actions")

do {
    let outputs = RemoteOutputOwnership(), a = UUID(), b = UUID()
    var downs = 0, repeats = 0, ups = 0
    outputs.emit = { _,down in if down { downs += 1 } else { ups += 1 } }
    outputs.pressAgain = { _ in repeats += 1 }
    outputs.send(owner:a,key:0x28,down:true)
    outputs.send(owner:b,key:0x28,down:true)
    outputs.send(owner:b,key:0x28,down:true)
    check(downs == 1 && repeats == 1,"independent second Return press is delivered, duplicate owner edge ignored")
    outputs.release(a); check(ups == 0,"Return held by another device stays held")
    outputs.release(b); check(ups == 1,"final owner releases Return")
}
print("PASS: overlapping ordinary keys deliver each device's press without duplicate edges or premature release")

// Optional installed-settings copy, never the live Application Support folder.
if let path = ProcessInfo.processInfo.environment["YAOBAN_UPGRADE_FIXTURE"] {
    let fixture = URL(fileURLWithPath:path).standardizedFileURL
    check(fixture.lastPathComponent == "v080-live-copy" && fixture.deletingLastPathComponent().lastPathComponent == ".build","upgrade verification requires an isolated build copy")
    let directory = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("yaoban-upgrade-replay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at:directory) }
    let fixtureSettings = try PrivateFiles.read(fixture.appendingPathComponent("按键设置.json"))
    let fixtureBinding = try PrivateFiles.read(fixture.appendingPathComponent("遥控器绑定.json"))
    let fixtureDevices = try PrivateFiles.read(fixture.appendingPathComponent("设备库.json"))
    try PrivateFiles.write(fixtureSettings,to:directory.appendingPathComponent("按键设置.json"))
    try PrivateFiles.write(fixtureBinding,to:directory.appendingPathComponent("遥控器绑定.json"))
    try PrivateFiles.write(fixtureDevices,to:directory.appendingPathComponent("设备库.json"))
    let store = MappingStore(directory:directory), devices = RemoteDeviceStore(directory:directory)
    let bindingURL = directory.appendingPathComponent("遥控器绑定.json")
    let settingsBefore = try PrivateFiles.read(store.url), bindingBefore = try PrivateFiles.read(bindingURL)
    let original = try store.load().library
    let loaded = try store.loadForApp().library
    let legacyDevices = try devices.load(migrating:bindingURL,profiles:loaded)
    let prepared = try DevicePresetTransaction.prepareForLaunch(profiles:loaded,devices:legacyDevices,store:store,deviceStore:devices)
    let result = prepared.devices
    check(result.devices.count == 1 && result.selected.flatMap({ prepared.profiles.profile(id:$0.profileID,for:$0.binding.model.id) }) != nil && result.selected?.startupProfileID == result.selected?.profileID,"actual copied device receives a model-owned startup profile")
    check(result.selected?.configuration == legacyDevices.selected?.configuration,"actual copied short/long/repeat/mouse keys migrate exactly")
    check(original.profiles.allSatisfy { prepared.profiles.profiles.contains($0) },"model migration preserves every original profile and its settings")
    check(try PrivateFiles.read(bindingURL) == bindingBefore,"legacy binding remains byte-for-byte unchanged")
    if try PrivateFiles.read(store.url) != settingsBefore {
        check(try PrivateFiles.read(store.modelMigrationBackupURL) == settingsBefore,"preset upgrade retains the exact pre-v8 settings in its dedicated backup")
    }
    check(try PrivateFiles.read(fixture.appendingPathComponent("按键设置.json")) == fixtureSettings && PrivateFiles.read(fixture.appendingPathComponent("遥控器绑定.json")) == fixtureBinding && PrivateFiles.read(fixture.appendingPathComponent("设备库.json")) == fixtureDevices,"replaying the upgrade never mutates the source fixture")
    check(try devices.load(migrating:bindingURL,profiles:prepared.profiles) == result,"actual copied migration persists on reload")
    print("PASS: installed-settings copy preserves all original profiles, active short/long/repeat settings and binding; adds presets with backup; source fixture unchanged; reopen matches")
}

do {
    let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("yaoban-invalid-device-settings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at:root) }
    let store = MappingStore(directory:root), devices = RemoteDeviceStore(directory:root)
    var profiles = try store.loadForApp().library
    var config = profiles.selected.configuration; config.triggers[0x35] = .release
    let item = SavedRemote(name:"retired config",binding:RemoteBinding(peripheralID:UUID(),hidIdentity:"ble:1"),profileID:profiles.selectedID,configuration:config)
    let library = RemoteDeviceLibrary(selectedID:item.id,devices:[item])
    do { try devices.save(library); fatalError("retired trigger accepted in device schema") } catch {}
    check(!FileManager.default.fileExists(atPath:devices.url.path),"invalid device configuration creates no file")
    profiles.profiles[profiles.selectedIndex].configuration = config
    do { try DevicePresetTransaction.commit(profiles:profiles,devices:RemoteDeviceLibrary(),store:store,deviceStore:devices); fatalError("retired template accepted in transaction") } catch {}
    check(!FileManager.default.fileExists(atPath:DevicePresetTransaction.url(store).path),"invalid mode rejected before durable intent")
}
print("PASS: retired combination/guide actions rejected before device write or transaction creation")

// The exact preset/device round-trip must carry touch settings without changing keys.
do {
    let touchStore = MappingStore(directory:auditRoot.appendingPathComponent("touch-settings"))
    let previous = try touchStore.loadForApp().configuration
    for mode in RemoteTouchSettings.Mode.allCases {
        _ = try touchStore.editProfiles { $0.profiles[$0.selectedIndex].configuration.touch = .init(mode:mode,speed:1.7) }
        let loaded = try MappingStore(directory:touchStore.directory).load().configuration
        check(loaded.touch == RemoteTouchSettings(mode:mode,speed:1.7) && loaded.bindings == previous.bindings && loaded.longBindings == previous.longBindings,"preset reload preserves touch and existing short/long keys")
        check(try JSONDecoder().decode(MappingConfiguration.self,from:JSONEncoder().encode(loaded)) == loaded,"device/retained configuration round-trip includes touch")
    }
    let bytes = try PrivateFiles.read(touchStore.url)
    for speed in [0.49,3.01,Double.nan,Double.infinity] {
        do { _ = try touchStore.editProfiles { $0.profiles[$0.selectedIndex].configuration.touch.speed = speed }; fatalError("invalid touch speed") } catch {}
        check(try PrivateFiles.read(touchStore.url) == bytes,"invalid touch does not replace saved keys")
    }

    // The last published preset schema remains readable, but the first gesture
    // save must advertise v9 so an older app cannot silently erase it.
    var versionEight = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
    versionEight["version"] = 8
    versionEight["profiles"] = (versionEight["profiles"] as! [[String:Any]]).map { row -> [String:Any] in
        var row = row
        if var touch = row["touch"] as? [String:Any] {
            for key in ["gestureBindings","tapInterval","ringStartRadius","swipeDistance"] { touch.removeValue(forKey:key) }
            row["touch"] = touch
        }
        return row
    }
    try PrivateFiles.write(JSONSerialization.data(withJSONObject:versionEight),to:touchStore.url)
    let loadedV8 = try touchStore.load().configuration
    check(loadedV8.touch.mode == .hybrid && loadedV8.touch.speed == 1.7 && loadedV8.touch.maximumConfiguredTapCount == 0,"v8 touch settings migrate with inert gesture defaults")
    _ = try touchStore.editProfiles { $0.profiles[$0.selectedIndex].configuration.touch.setBinding([0xE0,0x28],for:.tap1) }
    let versionNineBytes = try PrivateFiles.read(touchStore.url)
    check((try JSONSerialization.jsonObject(with:versionNineBytes) as! [String:Any])["version"] as? Int == 9,"first gesture preset save does not remain writable by v8 apps")
    check(try touchStore.load().configuration.touch.binding(for:.tap1) == [0xE0,0x28],"v8-to-v9 gesture save survives reopen")

    var legacy = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
    legacy["version"] = 6
    legacy["profiles"] = (legacy["profiles"] as! [[String:Any]]).map { value -> [String:Any] in var v=value;v.removeValue(forKey:"touch");return v }
    try PrivateFiles.write(JSONSerialization.data(withJSONObject:legacy),to:touchStore.url)
    check(try touchStore.load().configuration.touch == RemoteTouchSettings(),"v6 remains touch-off and preserves old defaults")

    // Device schema v3 also predates gesture bindings. Reading is lossless and
    // any subsequent gesture write is marked v4 for old-app overwrite safety.
    let deviceDirectory = auditRoot.appendingPathComponent("touch-device-schema")
    let deviceStore = RemoteDeviceStore(directory:deviceDirectory)
    let deviceConfiguration = RemoteButtonLayout.configuration(BuiltInPreset.appleCodex.configuration,for:.apple)
    let device = SavedRemote(name:"gesture migration",binding:.unbound(model:.apple),profileID:BuiltInPreset.appleCodex.id,configuration:deviceConfiguration)
    try deviceStore.save(RemoteDeviceLibrary(selectedID:device.id,devices:[device]))
    var versionThree = try JSONSerialization.jsonObject(with:PrivateFiles.read(deviceStore.url)) as! [String:Any]
    versionThree["version"] = 3
    versionThree["devices"] = (versionThree["devices"] as! [[String:Any]]).map { row -> [String:Any] in
        var row = row, configuration = row["configuration"] as! [String:Any]
        var touch = configuration["touch"] as! [String:Any]
        for key in ["gestureBindings","tapInterval","ringStartRadius","swipeDistance"] { touch.removeValue(forKey:key) }
        configuration["touch"] = touch; row["configuration"] = configuration
        return row
    }
    try PrivateFiles.write(JSONSerialization.data(withJSONObject:versionThree),to:deviceStore.url)
    var migratedDevice = try deviceStore.load(migrating:deviceDirectory.appendingPathComponent("absent.json"),profiles:try touchStore.load().library)
    check(migratedDevice.version == 4 && migratedDevice.selected?.configuration.touch.maximumConfiguredTapCount == 0,"v3 device touch settings migrate with inert gesture defaults")
    migratedDevice.devices[0].configuration.touch.setBinding([0xE1,0x04],for:.tap2)
    try deviceStore.save(migratedDevice)
    let versionFourBytes = try PrivateFiles.read(deviceStore.url)
    check((try JSONSerialization.jsonObject(with:versionFourBytes) as! [String:Any])["version"] as? Int == 4,"first gesture device save does not remain writable by v3 apps")
    check(try deviceStore.load(migrating:deviceDirectory.appendingPathComponent("absent.json"),profiles:try touchStore.load().library).selected?.configuration.touch.binding(for:.tap2) == [0xE1,0x04],"v3-to-v4 device gesture save survives reopen")

    let channel = ConsumingKeyboardChannel()
    let output = KeyboardEmitter(channel:channel,scheduleReceiptCheck:{ _ in },pointerSnapshot:{ (CGPoint(x:500,y:500),[]) })
    _ = output.start(); output.movePointer(x:0.02,y:0.01,scroll:false)
    check(channel.events.count == 1 && !output.isObserving && channel.starts == 0 && channel.snapshotReads == 0,"touch movement posts without starting a global keyboard listener")
    output.movePointer(x:Double.nan,y:0,scroll:false); output.movePointer(x:2,y:0,scroll:false)
    check(channel.events.count == 1,"nonfinite or unbounded pointer motion rejected")
    output.movePointer(x:0,y:0.02,scroll:true)
    check(channel.events.last!.type == .scrollWheel,"scroll mode posts only a scroll event")
    output.send(0xF101,down:true); output.movePointer(x:0.02,y:0,scroll:false)
    check(channel.events.last!.type == .leftMouseDragged,"held mapped left mouse combines with touch dragging")
    output.send(0xF101,down:false); output.stop()
    let count = channel.events.count; output.movePointer(x:0.02,y:0,scroll:false)
    check(channel.events.count == count,"stopped output cannot move pointer")
    print("PASS: touch preset/device persistence, v8→v9 and v3→v4 gesture migration, v6 defaults, invalid-save rollback, pointer/scroll/drag output and idle privacy")
}
