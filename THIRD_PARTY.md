# 遥伴 Yovolpen：开源许可与来源

更新：2026-09-15；对应 0.10.8 公开测试候选。

本项目按 GNU GPL version 3 分发，完整文本见 `LICENSE`。发布安装包须同时提供对应版本的源码与构建脚本。各第三方组件保留其原有版权与许可；品牌名称用于说明来源或兼容关系，不表示合作或背书。

## Open Voice Bridge

来源：https://github.com/nijez/open-voice-bridge
参考版本：`1796b149f752ff2d2fa82fd818f8a5a2bc60802a`；作者为该项目贡献者；GPL-3.0。

`Sources/MiRemoteLab/ATVVProtocol.swift` 与取得的上游文件逐字节一致。小米 HID 格式、ATVV 握手及按键恢复方案参考该项目 RemoteButtons、XiaomiBluetoothBridge、RemoteVoiceFunctionMapper。其余本项目实现及修改按项目 GPL-3.0 许可提供。上游许可保留于 `Assets/Licenses/OpenVoiceBridge-GPL-3.0`。

## BlackHole

来源：https://github.com/ExistentialAudio/BlackHole
版本：v0.7.1，`e2b22aaaba4e507a097131704bf96dabc004d9cf`。
版权：Existential Audio Inc. 与贡献者；GPL-3.0。

完整单文件驱动源及许可位于 `Vendor/BlackHole`。本项目通过 `Driver/DriverConfig.h` 设置独立设备名称、UID、工厂标识和 48 kHz 音频格式。`scripts/build-audio-driver.py` 生成工作副本，将传输类型改报 USB 以兼容输入法，原有 vendored C 文件不修改。它仍是虚拟麦克风，不是物理 USB 麦克风。该兼容方案参考 https://github.com/HD838A/remote-mic-app 的 `c9fabd1ef53e1a311dab4518a70693494631368b`。安装只管理本项目 MiRemoteMic.driver。

## Opus

来源：https://opus-codec.org/；版本 1.6.1；版权属于 Opus 的各原作者。

应用静态链接本地编译的 libopus。完整原始源码及原有声明见 `Vendor/Opus/opus-1.6.1.tar.gz`，构建方法见 `scripts/build-opus.sh`。未修改上游源码。版权、免责声明和专利相关说明保留于 `Assets/Licenses/Opus-COPYING` 及源码归档。许可说明：https://opus-codec.org/license/ 。

## SiriRemoteForge

来源：https://github.com/HOLODATA-COM/SiriRemoteForge
研究版本：`4c65969c71c5`；版权属于该项目贡献者；GPL-3.0-or-later。

Apple 蓝牙包到 Opus 音频的处理流程、首次启用方式参考该项目。遥伴实现自己的设备筛选、包重组、限时采集、本地服务及虚拟声卡接入。上游 GPL 文本保留于 `Assets/Licenses/SiriRemoteForge-GPL-3.0`；本项目相关实现源码随版本提供。未分发其完整应用或安装包。

## Apple 工具与项目图形

PacketLogger 是 Apple 专有工具，不包含在遥伴安装包或源码归档中。需要 Apple 遥控器语音的用户自行从 Apple 官方渠道获取；安装程序验证已有工具，没有该工具也允许安装。系统框架和开发工具由 macOS / Apple 提供。

0.10.8 不再包含小米官方产品照片。界面小型遥控器示意图由本项目通过图片生成工具制作，品牌图形为本项目生成素材。Apple、小米、豆包、OpenAI 等商标不因本项目开源而授予任何商标权利。
