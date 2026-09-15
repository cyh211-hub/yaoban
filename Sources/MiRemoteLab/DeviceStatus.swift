import Foundation

struct RemoteModel: Equatable {
    let id: String
    let brand: String
    let name: String
    let supported: Bool
    static let xiaomi = RemoteModel(id: "xiaomi-rc003", brand: "小米", name: "蓝牙遥控器 2 Pro", supported: true)
    static let apple = RemoteModel(id: "apple-siri-remote", brand: "Apple", name: "Siri Remote 第 3 代", supported: true)
    static let appleSecond = RemoteModel(id: "apple-siri-remote-2", brand: "Apple", name: "Siri Remote 第 2 代", supported: false)
    static let appleFirst = RemoteModel(id: "apple-siri-remote-1", brand: "Apple", name: "Siri Remote 第 1 代", supported: false)
    static let catalog = [xiaomi, apple, appleSecond, appleFirst]
    var title: String { "\(brand) · \(name)" }
}

enum RemoteRadio { case checking, ready, off, unauthorized, unsupported }
enum RemoteConnection: String { case unbound = "未绑定设备", unselected = "尚未添加遥控器", connected = "已连接", disconnected = "已断开", checking = "正在检测", inputPermission = "需要输入监控权限", bluetoothOff = "蓝牙已关闭", permission = "需要蓝牙权限", unavailable = "蓝牙不可用", paused = "服务已暂停" }

// Presentation is derived from independent signals, not translated log strings.
// A live keyboard connection remains usable even when the audio permission is missing.
struct RemoteDeviceStatus: Equatable {
    let connection: RemoteConnection
    let keyboard: String
    let microphone: String
    let hint: String
    static func resolve(bound: Bool, stopped: Bool, present: Bool, radio: RemoteRadio,
                        inputAllowed: Bool, outputAllowed: Bool, mappingReady: Bool,
                        microphoneEnabled: Bool, voiceReady: Bool, driverAvailable: Bool,
                        outputFailure: String? = nil, pairingChanged: Bool = false, hasBinding: Bool = true) -> RemoteDeviceStatus {
        guard bound else { return .init(connection: .unselected, keyboard: "尚未添加设备", microphone: "尚未添加设备", hint: "在“遥控器”页面添加型号，再选择蓝牙设备。") }
        guard hasBinding else { return .init(connection:.unbound,keyboard:"未绑定设备",microphone:"未绑定设备",hint:"在“遥控器”页面选择要绑定的蓝牙设备。") }
        guard !stopped else { return .init(connection: .paused, keyboard: "已暂停", microphone: "已暂停", hint: "点击“重新检测”恢复服务。") }
        let connection: RemoteConnection
        if present { connection = .connected }
        else { switch radio {
        case .ready: connection = inputAllowed ? .disconnected : .inputPermission
        case .off: connection = .bluetoothOff
        case .unauthorized: connection = .permission
        case .unsupported: connection = .unavailable
        case .checking: connection = .checking
        } }
        let keyboard = !inputAllowed ? "需要输入监控权限" : !outputAllowed ? "需要辅助功能权限" : outputFailure != nil ? "发送异常，请重新检测" : !present ? "等待连接" : mappingReady ? "已就绪" : "正在准备"
        let microphone = !microphoneEnabled ? "已关闭" : radio == .unauthorized ? "需要蓝牙权限" : pairingChanged ? "需重新选择设备" : !present ? "等待连接" : !driverAvailable ? "需要安装麦克风组件" : voiceReady ? "已就绪" : "等待语音通道"
        let hint: String
        switch connection {
        case .connected: hint = "按键和麦克风的可用状态分别显示。"
        case .disconnected: hint = "轻按遥控器唤醒。若在系统中忽略并重新配对，请在设备列表重新选择蓝牙设备；已有键位保留。"
        case .bluetoothOff: hint = "请在系统蓝牙设置中开启蓝牙。"
        case .inputPermission: hint = "请开启输入监控权限。"
        case .permission: hint = "请在系统隐私设置中允许“遥伴”使用蓝牙。"
        case .unavailable: hint = "系统蓝牙当前不可用，请检查蓝牙设置。"
        default: hint = "正在检测所选遥控器，请稍候。"
        }
        return .init(connection: connection, keyboard: keyboard, microphone: microphone,
            hint: pairingChanged ? "系统配对记录已变化，后台已停止重试。请在系统中完成配对，再在设备列表重新选择蓝牙设备；已有键位和模式会保留。" : outputFailure ?? hint)
    }
}
