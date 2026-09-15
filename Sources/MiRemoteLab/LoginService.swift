// Xiaomi Remote Lab — GPL-3.0.
import AppKit
import ServiceManagement

extension LabApp {
    func configureLogin() {
        guard !isPreview else { return }
        if (!UserDefaults.standard.bool(forKey:"loginConfiguredV04") || ProcessInfo.processInfo.arguments.contains("--migrate-login")), Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            do {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                UserDefaults.standard.set(true,forKey:"loginConfiguredV04")
            } catch { log("自动启动尚未启用：\(error.localizedDescription)") }
        }
        refreshLoginState()
        log("后台启动：" + loginLabel.stringValue)
    }
    func refreshLoginState() {
        let status = SMAppService.mainApp.status
        loginToggle.state = status == .enabled || status == .requiresApproval ? .on : .off
        switch status {
        case .enabled: loginLabel.stringValue = "已启用 · 登录后在菜单栏运行，关闭设置窗口不影响输入。"
        case .requiresApproval: loginLabel.stringValue = "等待系统允许。请在“管理系统登录项”中开启遥伴。"
        case .notRegistered: loginLabel.stringValue = "未开启自动启动。手动运行后，关闭设置窗口仍可继续输入。"
        default: loginLabel.stringValue = "请从应用程序文件夹运行，并在系统登录项中检查状态。"
        }
    }
    @objc func loginChanged() {
        guard !isPreview else { loginToggle.state = .off; loginLabel.stringValue = "界面预览不更改系统登录项。"; return }
        do {
            if loginToggle.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(true,forKey:"loginConfiguredV04"); refreshLoginState()
        } catch { refreshLoginState(); loginLabel.stringValue = "更改未完成：\(error.localizedDescription)" }
    }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
