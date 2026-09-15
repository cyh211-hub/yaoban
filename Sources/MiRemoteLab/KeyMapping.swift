// Xiaomi Remote Lab — GPL-3.0.
import Foundation

struct KeyboardKey: Equatable {
    let usage: UInt16
    let code: UInt16
    let name: String
    var isModifier: Bool { (0xE0...0xE7).contains(usage) }
    var isMouse: Bool { (0xF101...0xF105).contains(usage) }
    var isScroll: Bool { usage == 0xF104 || usage == 0xF105 }
    static let all: [KeyboardKey] = {
        let modifiers: [(UInt16, UInt16, String)] = [
            (0xE7,54,"右 ⌘ Command"), (0xE3,55,"左 ⌘ Command"),
            (0xE6,61,"右 ⌥ Option"), (0xE2,58,"左 ⌥ Option"),
            (0xE5,60,"右 ⇧ Shift"), (0xE1,56,"左 ⇧ Shift"),
            (0xE4,62,"右 ⌃ Control"), (0xE0,59,"左 ⌃ Control")]
        let letterCodes: [UInt16] = [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
        let letters = letterCodes.enumerated().map { (UInt16(4 + $0.offset), $0.element, String(UnicodeScalar(65 + $0.offset)!)) }
        let digits: [(UInt16,UInt16,String)] = [(0x1E,18,"1"),(0x1F,19,"2"),(0x20,20,"3"),(0x21,21,"4"),(0x22,23,"5"),(0x23,22,"6"),(0x24,26,"7"),(0x25,28,"8"),(0x26,25,"9"),(0x27,29,"0")]
        let other: [(UInt16,UInt16,String)] = [
            (0x28,36,"Return 回车"),(0x29,53,"Escape"),(0x2A,51,"Delete 退格"),(0x2B,48,"Tab"),(0x2C,49,"空格"),
            (0x2D,27,"−"),(0x2E,24,"="),(0x2F,33,"["),(0x30,30,"]"),(0x31,42,"\\"),(0x33,41,";"),(0x34,39,"'"),(0x35,50,"`"),(0x36,43,","),(0x37,47,"."),(0x38,44,"/"),(0x39,57,"Caps Lock"),
            (0x4A,115,"Home"),(0x4B,116,"Page Up"),(0x4C,117,"Forward Delete"),(0x4D,119,"End"),(0x4E,121,"Page Down"),
            (0x4F,124,"→"),(0x50,123,"←"),(0x51,125,"↓"),(0x52,126,"↑")]
        let fCodes: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        let functions = fCodes.enumerated().map { (UInt16($0.offset < 12 ? 0x3A + $0.offset : 0x68 + $0.offset - 12), $0.element, "F\($0.offset + 1)") }
        let mouse: [(UInt16,UInt16,String)] = [(0xF101,0xFF01,"鼠标左键"),(0xF102,0xFF02,"鼠标右键"),(0xF103,0xFF03,"鼠标中键"),(0xF104,0xFF04,"滚轮向上"),(0xF105,0xFF05,"滚轮向下")]
        return (modifiers + letters + digits + other + functions + mouse).map { KeyboardKey(usage: $0.0, code: $0.1, name: $0.2) }
    }()
    static func find(_ usage: UInt16) -> KeyboardKey? { all.first { $0.usage == usage } }
    static func normalized(_ usages: [UInt16]) -> [UInt16] {
        Set(usages).sorted { a, b in
            let am = (0xE0...0xE7).contains(a), bm = (0xE0...0xE7).contains(b)
            return am == bm ? a < b : am
        }
    }
    static func compactDescription(_ usages: [UInt16]) -> String {
        if usages.isEmpty { return "不执行" }
        let modifiers: [UInt16:String] = [0xE0:"左⌃",0xE1:"左⇧",0xE2:"左⌥",0xE3:"左⌘",0xE4:"右⌃",0xE5:"右⇧",0xE6:"右⌥",0xE7:"右⌘"]
        return normalized(usages).map { modifiers[$0] ?? ($0 == 0x28 ? "Return" : $0 == 0x2A ? "Delete" : find($0)?.name ?? "?") }.joined(separator:" + ")
    }
    static func describe(_ usages: [UInt16]) -> String {
        if usages.isEmpty { return "禁用此键" }
        return normalized(usages).map { find($0)?.name ?? String(format: "0x%X", $0) }.joined(separator: " + ")
    }
}

enum ActionTrigger: String, Codable, CaseIterable {
    case hold, repeating, shortLong, release
    // release is decoded only to migrate the retired guide-key setting.
    static let selectable: [ActionTrigger] = [.hold, .repeating, .shortLong]
    static let repeatingSources: Set<UInt16> = [0x52,0x51,0x50,0x4F,0xF1,0x80,0x81]
    static func defaultMode(for source: UInt16) -> ActionTrigger { repeatingSources.contains(source) ? .repeating : .hold }
    var title: String {
        switch self {
        case .hold: return "普通"
        case .release: return "普通"
        case .shortLong: return "短按／长按"
        case .repeating: return "长按连发"
        }
    }
}

struct RemoteCombination: Codable, Equatable {
    var id: String = UUID().uuidString
    var sources: [UInt16]
    var keys: [UInt16]
    var trigger: ActionTrigger = .hold
    var leader: UInt16? = nil
    var title: String {
        guard let leader else { return RemoteReport.name(Set(sources)) }
        return "按住 \(RemoteReport.names[leader] ?? "?") → \(RemoteReport.name(Set(sources).subtracting([leader])))"
    }
    init(id: String = UUID().uuidString, sources: [UInt16], keys: [UInt16], trigger: ActionTrigger = .hold, leader: UInt16? = nil) {
        self.id = id; self.sources = sources; self.keys = keys; self.trigger = trigger; self.leader = leader
    }
    enum CodingKeys: String, CodingKey { case id, sources, keys, trigger, leader }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); sources = try c.decode([UInt16].self, forKey: .sources)
        keys = try c.decode([UInt16].self, forKey: .keys)
        trigger = try c.decodeIfPresent(ActionTrigger.self, forKey: .trigger) ?? .hold
        leader = try c.decodeIfPresent(UInt16.self, forKey: .leader)
    }
}

enum RemoteTouchGesture: String, Codable, CaseIterable {
    case tap1, tap2, tap3
    case swipeUp, swipeDown, swipeLeft, swipeRight

    var tapCount: Int? {
        switch self {
        case .tap1: return 1
        case .tap2: return 2
        case .tap3: return 3
        default: return nil
        }
    }
    static func tap(_ count: Int) -> Self? {
        switch count {
        case 1: return .tap1
        case 2: return .tap2
        case 3: return .tap3
        default: return nil
        }
    }
    // Directional usages preserve the pre-gesture swipe behavior when no
    // explicit swipe binding is stored.
    var legacySource: UInt16? {
        switch self {
        case .swipeUp: return 0x52
        case .swipeDown: return 0x51
        case .swipeLeft: return 0x50
        case .swipeRight: return 0x4F
        default: return nil
        }
    }
}

struct RemoteTouchSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case off, pointer, scroll, swipe, hybrid
        var title: String {
            switch self {
            case .off: return "关闭"
            case .pointer: return "鼠标"
            case .scroll: return "滚动"
            case .swipe: return "四向滑动"
            case .hybrid: return "外环旋钮 + 内部鼠标"
            }
        }
    }
    var mode: Mode = .off
    var speed: Double = 1
    var acceleration = true
    static let defaultGestureBindings: [RemoteTouchGesture: [UInt16]] = [.tap1:[], .tap2:[], .tap3:[]]
    var gestureBindings: [RemoteTouchGesture: [UInt16]] = defaultGestureBindings
    var tapInterval: Double = 0.3
    var ringStartRadius: Double = 0.35
    var swipeDistance: Double = 0.17
    init(mode:Mode = .off,speed:Double = 1,acceleration:Bool = true,
         gestureBindings:[RemoteTouchGesture:[UInt16]] = defaultGestureBindings,
         tapInterval:Double = 0.3,ringStartRadius:Double = 0.35,swipeDistance:Double = 0.17) {
        self.mode = mode; self.speed = speed; self.acceleration = acceleration
        self.gestureBindings = gestureBindings; self.tapInterval = tapInterval
        self.ringStartRadius = ringStartRadius; self.swipeDistance = swipeDistance
    }
    enum CodingKeys: String, CodingKey {
        case mode, speed, acceleration, gestureBindings, tapInterval, ringStartRadius, swipeDistance
    }
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self,forKey:.mode) ?? .off
        speed = try c.decodeIfPresent(Double.self,forKey:.speed) ?? 1
        acceleration = try c.decodeIfPresent(Bool.self,forKey:.acceleration) ?? true
        let stored = try c.decodeIfPresent([String:[UInt16]].self,forKey:.gestureBindings)
        if let stored {
            var decoded: [RemoteTouchGesture:[UInt16]] = [:]
            for (raw, keys) in stored {
                guard let gesture = RemoteTouchGesture(rawValue:raw) else {
                    throw DecodingError.dataCorruptedError(forKey:.gestureBindings,in:c,debugDescription:"Unknown touch gesture: \(raw)")
                }
                decoded[gesture] = keys
            }
            gestureBindings = decoded
        } else { gestureBindings = Self.defaultGestureBindings }
        tapInterval = try c.decodeIfPresent(Double.self,forKey:.tapInterval) ?? 0.3
        ringStartRadius = try c.decodeIfPresent(Double.self,forKey:.ringStartRadius) ?? 0.35
        swipeDistance = try c.decodeIfPresent(Double.self,forKey:.swipeDistance) ?? 0.17
    }
    func encode(to encoder:Encoder) throws {
        var c = encoder.container(keyedBy:CodingKeys.self)
        try c.encode(mode,forKey:.mode); try c.encode(speed,forKey:.speed)
        try c.encode(acceleration,forKey:.acceleration)
        let stored = Dictionary(uniqueKeysWithValues:gestureBindings.map { ($0.key.rawValue,$0.value) })
        try c.encode(stored,forKey:.gestureBindings)
        try c.encode(tapInterval,forKey:.tapInterval)
        try c.encode(ringStartRadius,forKey:.ringStartRadius)
        try c.encode(swipeDistance,forKey:.swipeDistance)
    }
    func binding(for gesture:RemoteTouchGesture) -> [UInt16]? { gestureBindings[gesture] }
    mutating func setBinding(_ keys:[UInt16]?,for gesture:RemoteTouchGesture) {
        gestureBindings[gesture] = keys.map(KeyboardKey.normalized)
    }
    var maximumConfiguredTapCount: Int {
        gestureBindings.compactMap { gesture, keys in keys.isEmpty ? nil : gesture.tapCount }.max() ?? 0
    }
    // The persisted 0.5...3 value is now a UI speed level. These calibrated values are
    // explicit output-rate ceilings; acceleration is applied before the final clamp.
    var maximumPointerSpeed: Double { 0.35 + 0.30*speed }
    var maximumScrollSpeed: Double { 0.45 + 0.45*speed }
    func validated() throws -> Self {
        func validKeys(_ keys:[UInt16]) -> Bool {
            keys.count <= 9 && keys.filter { KeyboardKey.find($0)?.isMouse == true }.count <= 1 &&
            keys.allSatisfy { KeyboardKey.find($0) != nil }
        }
        guard speed.isFinite, (0.5...3).contains(speed),
              tapInterval.isFinite, (0.2...0.6).contains(tapInterval),
              ringStartRadius.isFinite, (0.2...0.45).contains(ringStartRadius),
              swipeDistance.isFinite, (0.1...0.5).contains(swipeDistance),
              gestureBindings.count <= RemoteTouchGesture.allCases.count,
              gestureBindings.values.allSatisfy(validKeys) else {
            throw NSError(domain:"Mapping",code:1,userInfo:[NSLocalizedDescriptionKey:"圆盘手势设置无效。"] )
        }
        var result = self
        result.gestureBindings = gestureBindings.mapValues(KeyboardKey.normalized)
        return result
    }
}

struct MappingConfiguration: Codable, Equatable {
    // Snapshot of the user's codex v1 layout, September 9, 2026.
    static let defaultBindings: [UInt16: [UInt16]] = [
        0x3E:[0xE7], 0x28:[0xE2,0x28], 0x66:[0x28], 0xF1:[0x2A],
        0x52:[0x52], 0x51:[0x51], 0x50:[0x50], 0x4F:[0x4F],
        0x4A:[0xE3,5], 0x65:[0xE1,0xE3,8], 0x80:[0xE0,0x2B],
        0x81:[0xE0,0xE1,0x2B], 0x35:[0xE2,0xE3,5]]
    // Missing = original behavior; empty = disabled.
    var bindings: [UInt16: [UInt16]] = defaultBindings
    var combinations: [RemoteCombination] = []
    var longBindings: [UInt16: [UInt16]] = [:]
    var longPressDelay: Double = 0.6
    var repeatEnabled = true
    var triggers: [UInt16: ActionTrigger] = [:]
    var touch = RemoteTouchSettings()
    func trigger(for source: UInt16) -> ActionTrigger { triggers[source] ?? ActionTrigger.defaultMode(for: source) }
    init(bindings: [UInt16: [UInt16]] = defaultBindings, combinations: [RemoteCombination] = [], repeatEnabled: Bool = true, triggers: [UInt16: ActionTrigger] = [:], longBindings: [UInt16: [UInt16]] = [:], longPressDelay: Double = 0.6, touch: RemoteTouchSettings = .init()) {
        self.bindings = bindings; self.combinations = combinations; self.repeatEnabled = repeatEnabled
        self.triggers = triggers; self.longBindings = longBindings; self.longPressDelay = longPressDelay
        self.touch = touch
    }
    enum CodingKeys: String, CodingKey { case bindings, combinations, repeatEnabled, triggers, longBindings, longPressDelay, touch }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindings = try c.decode([UInt16:[UInt16]].self, forKey: .bindings)
        combinations = try c.decodeIfPresent([RemoteCombination].self, forKey: .combinations) ?? []
        repeatEnabled = try c.decodeIfPresent(Bool.self, forKey: .repeatEnabled) ?? true
        triggers = try c.decodeIfPresent([UInt16: ActionTrigger].self, forKey: .triggers) ?? [:]
        longBindings = try c.decodeIfPresent([UInt16: [UInt16]].self, forKey: .longBindings) ?? [:]
        longPressDelay = try c.decodeIfPresent(Double.self, forKey: .longPressDelay) ?? 0.6
        touch = try c.decodeIfPresent(RemoteTouchSettings.self, forKey:.touch) ?? .init()
    }
    func migratingLegacyPressActions() -> MappingConfiguration {
        var result = self
        result.combinations = []
        for (source, mode) in result.triggers where mode == .release {
            result.triggers[source] = ActionTrigger.defaultMode(for:source)
        }
        return result
    }

    func validated() throws -> MappingConfiguration {
        let validatedTouch = try touch.validated()
        func reject(_ text: String) -> Error { NSError(domain: "Mapping", code: 1, userInfo: [NSLocalizedDescriptionKey:text]) }
        func validKeys(_ keys: [UInt16]) -> Bool { keys.count <= 9 && keys.filter { KeyboardKey.find($0)?.isMouse == true }.count <= 1 && keys.allSatisfy { KeyboardKey.find($0) != nil } }
        guard bindings.allSatisfy({ RemoteButtonLayout.names[$0.key] != nil && validKeys($0.value) }), triggers.keys.allSatisfy({ RemoteButtonLayout.names[$0] != nil }) else {
            throw reject("保存的按键设置含有不支持的按键。")
        }
        guard longPressDelay.isFinite, (0.2...2.0).contains(longPressDelay),
              longBindings.allSatisfy({ RemoteButtonLayout.names[$0.key] != nil && validKeys($0.value) }),
              triggers.allSatisfy({ $0.value != .shortLong || bindings[$0.key] != nil }) else {
            throw reject("长按判定需为 0.2–2 秒；短按／长按需要指定映射或禁用短按，不能保持原键。")
        }
        guard combinations.count <= 64, Set(combinations.map { $0.id }).count == combinations.count else {
            throw reject("组合键重复或超过 64 组。")
        }
        var sources = Set<[UInt16]>()
        for combo in combinations {
            let normalized = Set(combo.sources).sorted()
            guard !combo.id.isEmpty, combo.id.count <= 64, (2...3).contains(combo.sources.count),
                  normalized.count == combo.sources.count, normalized.allSatisfy({ RemoteReport.names[$0] != nil }),
                  sources.insert([combo.leader ?? 0xFFFF] + normalized).inserted, !combo.keys.isEmpty, validKeys(combo.keys) else {
                throw reject("每组需要 2–3 个不同的遥控器按键、一个键盘目标，且不能重复。")
            }
            guard !Set(normalized).isSuperset(of: [0x4A,0x65]) else { throw reject("主页 + 菜单是遥控器的配对操作，不能用作快捷键。") }
            guard normalized.allSatisfy({ bindings[$0] != nil }) else {
                throw reject("组合中的按键需要先指定单键映射或禁用，不能设为“保持原键”。")
            }
            if let leader = combo.leader {
                guard normalized.contains(leader), leader != 0x3E, trigger(for:leader) == .release else {
                    throw reject("引导键必须属于该组合，并设为“松开执行一次”；不能使用连发键或麦克风键。请先修改或删除使用此键的组合。")
                }
            }
        }
        if combinations.contains(where:{ $0.leader != nil }) {
            guard RemoteReport.names.keys.allSatisfy({ bindings[$0] != nil }) else {
                throw reject("使用引导键时，所有遥控器按键都需要指定映射或禁用，不能“保持原键”，以确保未设置的组合不会触发原键。")
            }
        }
        return MappingConfiguration(bindings: bindings.mapValues(KeyboardKey.normalized), combinations: combinations.map {
            RemoteCombination(id:$0.id, sources:$0.sources.sorted(), keys:KeyboardKey.normalized($0.keys), trigger:$0.trigger, leader:$0.leader)
        }, repeatEnabled: repeatEnabled, triggers:triggers, longBindings:longBindings.mapValues(KeyboardKey.normalized), longPressDelay:longPressDelay, touch:validatedTouch)
    }
}

// Use the same verified down/up path for every custom binding, including raw
// Back and Power usages. A stored UserKeyMapping target is not proof of output.
// Missing bindings keep native behavior; empty bindings only suppress the key.
struct MappingPlan {
    let native: [UInt16: UInt16]
    let software: [UInt16: [UInt16]]
    let longPress: [UInt16: [UInt16]]
    init(bindings: [UInt16: [UInt16]]) {
        var native: [UInt16: UInt16] = [:]
        var software: [UInt16: [UInt16]] = [:]
        for (source, keys) in bindings {
            native[source] = 0
            if !keys.isEmpty {
                software[source] = KeyboardKey.normalized(keys)
            }
        }
        self.native = native; self.software = software; self.longPress = [:]
    }
    init(configuration: MappingConfiguration) {
        let single = MappingPlan(bindings:configuration.bindings)
        native = single.native; software = single.software
        longPress = configuration.longBindings.filter {
            configuration.bindings[$0.key] != nil && configuration.trigger(for:$0.key) == .shortLong && !$0.value.isEmpty
        }.mapValues(KeyboardKey.normalized)
    }
}

// Physical and app-owned keys have independent owners. CGEventSource.keyState
// after posting to HID may include the very key we posted, so cannot gate key-up.
struct KeyboardOutputState {
    private(set) var physical: Set<UInt16> = []
    private(set) var virtual: Set<UInt16> = []
    var combined: Set<UInt16> { physical.union(virtual) }
    mutating func physicalEdge(_ usage: UInt16, down: Bool) {
        if down { physical.insert(usage) } else { physical.remove(usage) }
    }
    mutating func virtualEdge(_ usage: UInt16, down: Bool) -> Bool {
        let before = combined.contains(usage)
        if down { virtual.insert(usage) } else { virtual.remove(usage) }
        return before != combined.contains(usage)
    }
    func flags(preserving flags: UInt64) -> UInt64 {
        let modifierBits = ModifierIdentity.genericMask | ModifierIdentity.sideMasks.values.reduce(0, |)
        return combined.reduce(flags & ~modifierBits) {
            $0 | ModifierIdentity.genericFlag($1) | (ModifierIdentity.sideMasks[$1] ?? 0)
        }
    }
}

enum ModifierIdentity {
    static let sideMasks: [UInt16: UInt64] = [0xE0:0x1, 0xE1:0x2, 0xE2:0x20, 0xE3:0x8, 0xE4:0x2000, 0xE5:0x4, 0xE6:0x40, 0xE7:0x10]
    static let genericMask: UInt64 = 0x1E0000
    static func genericFlag(_ usage: UInt16) -> UInt64 {
        switch usage {
        case 0xE0,0xE4: return 0x40000
        case 0xE1,0xE5: return 0x20000
        case 0xE2,0xE6: return 0x80000
        case 0xE3,0xE7: return 0x100000
        default: return 0
        }
    }
    // Accept exactly one modifier, with coherent key code and modifier flags.
    // No keycap/location inference and no left/right collapse.
    static func pressed(code: UInt16, flags: UInt64) -> UInt16? {
        guard let key = KeyboardKey.all.first(where: { $0.code == code && $0.isModifier }),
              flags & genericMask == genericFlag(key.usage) else { return nil }
        let sides = sideMasks.values.reduce(0, |)
        let actualSides = flags & sides
        guard actualSides == 0 || actualSides == sideMasks[key.usage] else { return nil }
        return key.usage
    }
    static func active(flags: UInt64, eventCode: UInt16, previous: Set<UInt16>) -> Set<UInt16> {
        var keys = Set(sideMasks.compactMap { flags & $0.value == 0 ? nil : $0.key })
        let eventUsage = KeyboardKey.all.first { $0.code == eventCode && $0.isModifier }?.usage
        for left: UInt16 in [0xE0,0xE1,0xE2,0xE3] where flags & genericFlag(left) != 0 {
            let family: Set<UInt16> = [left, left + 4]
            if !keys.isDisjoint(with: family) { continue }
            var fallback = previous.intersection(family)
            if let eventUsage, family.contains(eventUsage) {
                if fallback.contains(eventUsage) { fallback.remove(eventUsage) }
                else { fallback.insert(eventUsage) }
            }
            keys.formUnion(fallback)
        }
        return keys
    }
}

// Pure down/hold/up state machine. Each source owns its chord until release.
// Shared output keys stay down until every source that owns them is released.
final class ChordEngine {
    var emit: (UInt16, Bool) -> Void = { _, _ in }
    private var held: [UInt16: [UInt16]] = [:]
    private var previous = Set<UInt16>()
    private var outputs = Set<UInt16>()
    func update(_ next: Set<UInt16>, bindings: [UInt16: [UInt16]]) {
        for source in previous.subtracting(next) { held.removeValue(forKey: source) }
        for source in next.subtracting(previous) {
            if let keys = bindings[source], !keys.isEmpty { held[source] = keys }
        }
        previous = next
        transition(to: Set(held.values.flatMap { $0 }))
    }
    func releaseAll(blocking currentlyHeld: Set<UInt16> = []) {
        held = [:]; previous = currentlyHeld
        transition(to: [])
    }
    private func transition(to next: Set<UInt16>) {
        for key in KeyboardKey.normalized(Array(outputs.subtracting(next))).reversed() { emit(key, false) }
        for key in KeyboardKey.normalized(Array(next.subtracting(outputs))) { emit(key, true) }
        outputs = next
    }
}

struct MappingPair: Codable, Equatable {
    var source: UInt64
    var destination: UInt64
    static func usage(_ value: UInt16) -> UInt64 { 0x700000000 | UInt64(value) }
}

struct MappingSnapshot: Codable {
    let registryID: UInt64
    let original: [MappingPair]
    let installed: [MappingPair]
    func restoring(in current: [MappingPair]) -> [MappingPair] {
        var result = current
        // Preserve external changes and unrelated mappings, including duplicate entries.
        for pair in installed {
            guard result.filter({ $0.source == pair.source }) == [pair] else { continue }
            result.removeAll { $0.source == pair.source }
            result.append(contentsOf: original.filter { $0.source == pair.source })
        }
        return result
    }
}
