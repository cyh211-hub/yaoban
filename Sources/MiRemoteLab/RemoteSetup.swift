// Yaoban — GPL-3.0.
import Foundation

enum RemoteBindingReadiness: Equatable {
    case checking, bluetoothOff, bluetoothDenied, unsupported, inputPermission, noDevice, multipleDevices, ready
    static func resolve(radio: RemoteRadio, inputAllowed: Bool, bluetoothCount: Int, hidCount: Int) -> Self {
        switch radio {
        case .checking: return .checking
        case .off: return .bluetoothOff
        case .unauthorized: return .bluetoothDenied
        case .unsupported: return .unsupported
        case .ready: break
        }
        guard inputAllowed else { return .inputPermission }
        if bluetoothCount > 1 || hidCount > 1 { return .multipleDevices }
        guard bluetoothCount == 1, hidCount == 1 else { return .noDevice }
        return .ready
    }
    var message: String {
        switch self {
        case .checking: return "蓝牙正在准备。首次使用请允许系统蓝牙请求，稍候再点“选择并绑定”。"
        case .bluetoothOff: return "蓝牙已关闭。请先在系统蓝牙设置中开启蓝牙。"
        case .bluetoothDenied: return "尚未允许遥伴使用蓝牙。请在“隐私与安全性 → 蓝牙”中开启遥伴。"
        case .unsupported: return "系统蓝牙不可用，请检查电脑的蓝牙功能。"
        case .inputPermission: return "请先开启输入监控权限，以确认遥控器的按键设备。授权后回到这里再次选择。"
        case .noDevice: return "请先在系统蓝牙设置中配对并连接小米蓝牙遥控器 2 Pro，轻按方向键唤醒，再回来选择。"
        case .multipleDevices: return "发现多只设备，暂不绑定。为确认按键和麦克风来自同一只遥控器，请先断开其他同型号遥控器。"
        case .ready: return "已发现可绑定的遥控器，请确认所选设备。"
        }
    }
}
