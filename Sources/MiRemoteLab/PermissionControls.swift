import AppKit
import IOKit.hid

extension LabApp {
    func makePermissionsCard() -> NSView {
        inputPermissionButton.target = self; inputPermissionButton.action = #selector(permissions)
        outputPermissionButton.target = self; outputPermissionButton.action = #selector(keyPermissions)
        return card([label("权限",size:17,weight:.semibold),
            horizontal([label("输入监控"),spring(),inputPermissionStatus,inputPermissionButton]),
            horizontal([label("辅助功能"),spring(),outputPermissionStatus,outputPermissionButton])])
    }
    func refreshPermissionRows() {
        let read = isPreview || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let send = isPreview || CGPreflightPostEventAccess()
        for (granted,text,button) in [(read,inputPermissionStatus,inputPermissionButton),(send,outputPermissionStatus,outputPermissionButton)] {
            text.stringValue = granted ? "✓ 已授权" : "需要授权"
            text.textColor = granted ? .systemGreen : .systemRed
            button.isHidden = granted
        }
    }
    @objc func showSystemCheck() { showMainWindow(); selectPage(3) }
}
