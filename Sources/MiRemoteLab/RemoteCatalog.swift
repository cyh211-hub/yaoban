// Yaoban — GPL-3.0. Hardware facts and research sources: docs/apple-remote-adapter.md.
import Foundation

struct RemoteButtonDefinition: Equatable {
    let id: String
    let title: String
}

struct AppleRemoteDesign: Equatable {
    let model: RemoteModel
    let modelNumbers: String
    let identification: String
    let buttons: [RemoteButtonDefinition]
    let note: String
    // These are capability plans, never a signal to start an unverified driver.
    var hardwareVerified: Bool { false }
    var canActivate: Bool { model == .apple }
    var capabilitySummary: String {
        let buttons = model == .apple ? "实体按键：12 键输入已实测；提供按键映射测试版" : "实体按键：已规划，待实测"
        let actions = model == .apple ? "短按／长按／连发：已实测\n圆盘滑动：鼠标移动或页面滚动测试版，默认关闭" : "短按／长按／连发：待实测\n圆盘触控：待适配"
        return buttons + "\n" + actions + "\n电量：设备未上报时显示未知\n遥控器麦克风：待适配，不能直接作为系统麦克风"
    }
    static let modernButtons: [RemoteButtonDefinition] = [
        .init(id:"power",title:"电源"), .init(id:"up",title:"上"), .init(id:"down",title:"下"),
        .init(id:"left",title:"左"), .init(id:"right",title:"右"), .init(id:"center",title:"圆盘中心"),
        .init(id:"back",title:"返回"), .init(id:"tv",title:"TV / 控制中心"),
        .init(id:"siri",title:"Siri（侧边）"), .init(id:"playPause",title:"播放 / 暂停"),
        .init(id:"mute",title:"静音"), .init(id:"volumeUp",title:"音量 +"), .init(id:"volumeDown",title:"音量 −")]
    static let all: [AppleRemoteDesign] = [
        .init(model:.apple, modelNumbers:"A2854", identification:"第 3 代 · 银色 · USB-C · Bluetooth 5.0",
              buttons:modernButtons, note:"12 个非电源按键的按下与松开已实测；按键映射测试版已接入，触控和遥控器收音仍分别验证。"),
        .init(model:.appleSecond, modelNumbers:"A2540", identification:"第 2 代 · 银色 · Lightning · Bluetooth 5.0",
              buttons:modernButtons, note:"布局接近第 3 代，仍需独立核对设备标识和按键报告。"),
        .init(model:.appleFirst, modelNumbers:"A1513 / A1962", identification:"第 1 代 · 黑色触控面 · Lightning · Bluetooth 4.0",
              buttons:[.init(id:"center",title:"触控面按下"),.init(id:"menu",title:"菜单"),.init(id:"tv",title:"TV / 主屏幕"),.init(id:"siri",title:"Siri"),.init(id:"playPause",title:"播放 / 暂停"),.init(id:"volumeUp",title:"音量 +"),.init(id:"volumeDown",title:"音量 −")],
              note:"方向滑动属于触控输入，不当作实体方向键。旧款银色／白色 Apple Remote 使用红外，不属于蓝牙设备。")]
}

// A model adapter will normalize vendor reports to semantic IDs before loading
// presets. Xiaomi numeric usages must never be reused as Apple's raw usages.
enum RemoteAdapterCapability: String { case buttons, battery, touch, microphone }
protocol RemoteInputAdapter {
    var modelID: String { get }
    var verifiedCapabilities: Set<RemoteAdapterCapability> { get }
    func reset()
}
