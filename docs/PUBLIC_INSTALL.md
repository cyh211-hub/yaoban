# 安装遥伴 Yovolpen 0.10.8 公开测试版

当前候选适用于 Apple Silicon、macOS 26。未完成 Developer ID 签名和 Apple 公证。不同电脑、macOS 小版本和权限环境仍需测试。不要关闭系统安全保护来安装。

1. 下载发布页主安装包和校验和文件。首次安装不需要回退包。
2. 退出正在运行的遥伴，保留旧应用和设置。打开主安装包，按系统提示操作。安装脚本依赖 Apple 提供的 `/usr/bin/python3`；若系统缺少它，需要先安装 Apple Command Line Tools（这项当前安装要求尚未消除）。
3. 在“系统设置 → 隐私与安全性”中按提示给遥伴开启输入监控、辅助功能和蓝牙权限，再重开遥伴。本地临时签名的更新可能需要重新授权；程序不能自动替用户批准。
4. 在系统蓝牙中配对遥控器，再在遥伴添加对应型号并绑定该设备。已适配小米蓝牙遥控器 2 Pro、Apple Siri Remote 第三代 USB-C。已有设置应保留。
5. 根据需要选择系统输入设备“遥控器麦克风”，或继续使用原来的电脑/外接麦克风。识别文字由用户选择的输入法负责。

## 可选的 Apple 遥控器麦克风

仅需要 Apple 遥控器语音时，才需要 Apple 官方 PacketLogger。自行访问 https://developer.apple.com/download/all/ ，用 Apple 账号登录，寻找提供 PacketLogger 的 Additional Tools for Xcode，按 Apple 的条款获取，将 PacketLogger.app 放入应用程序文件夹。不要从不明镜像下载。

遥伴安装包不包含 PacketLogger。未安装它时，仍可使用遥控器按键/触控，并选择其他麦克风；小米语音不依赖 PacketLogger。Apple 语音工作依赖系统蓝牙诊断入口，其兼容性可能随系统变化。

## 退出与卸载

菜单栏退出只停止当前应用，不等同卸载后台组件。卸载前先停止语音，退出遥伴。不要直接删除系统服务或驱动目录；完整卸载流程尚未完成独立新机器验收，遇到需要清理组件时请通过反馈入口联系开发方。系统声音设置应恢复为其他可用输入设备。

## 反馈

提交设备型号、系统版本、操作步骤和现象即可。不公开上传私人录音、设备地址、密码或完整诊断日志。

GitHub：https://github.com/cyh211-hub/yovolpen/issues
Gitee：https://gitee.com/cyh830211/yovolpen/issues
