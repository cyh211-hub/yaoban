<div align="center">

<img src="media/遥伴-正式品牌标识.png" alt="遥伴" width="160">

# 遥伴 Yovolpen

让已适配的普通蓝牙遥控器成为 Mac 的语音与快捷操作入口。
面向桌面智能体、AI 编程与日常办公。

**公开测试版**

国内访问更快的 Gitee 镜像：[gitee.com/cyh830211/yovolpen](https://gitee.com/cyh830211/yovolpen)

</div>

## 它解决什么问题

还在为了一个想法反复伏案敲键盘吗？遥伴把已适配的普通蓝牙遥控器变成手边的输入伙伴：说出需求、按一下按键，让常用的键盘组合、鼠标操作和触控落在手边，把注意力留给思考和创作。

> 遥伴负责遥控器输入与按键映射；语音识别和 AI 任务执行由你选择的输入法或智能体完成。

## 三项核心能力

- **普通蓝牙遥控器**：已适配型号直接通过蓝牙接入，不另购专用语音输入配件。
- **语音输入**：把遥控器麦克风的声音送入系统虚拟麦克风，再交给你常用的输入法或智能体。
- **全部按键自定义**：每个按键可设为普通、长按连发或短按／长按，映射到键盘组合、鼠标点击或滚轮；支持多套预设。

![遥伴软件界面](media/软件界面-高清.png)

## 当前支持设备（测试版范围）

| 设备或功能 | 当前状态 | 说明 |
| --- | --- | --- |
| 小米蓝牙遥控器 2 Pro（RC003） | 已实机使用 | 按键、自定义映射与遥控器语音；其他小米型号不能据此视为兼容 |
| Apple Siri Remote USB-C 第三代 | 测试支持 | 按键、长按、媒体键映射与圆盘触控；电源键不开放映射 |
| Apple 遥控器语音 | 可选高级功能 | 需用户自行安装 Apple PacketLogger，见下文 |
| 其他小米 / Apple 遥控器代际 | 尚未开放 | 需逐代实机适配与验证，不能按外观或名称推定兼容 |

当前以 Apple Silicon / macOS 为主要开发与实机验证环境；公开测试包的最终系统范围以正式发布说明为准。

![多桌面智能体与办公场景](media/多桌面智能体-宣传海报.png)

## Apple 遥控器语音：可选高级功能

Apple Siri Remote 自身麦克风的完整链路为：

> Siri Remote 蓝牙语音数据 → Apple PacketLogger 捕获原始 HCI 数据 → 遥伴识别并重组语音帧 → Opus 解码 → “遥控器麦克风”虚拟声卡

- PacketLogger 是 Apple 在 Additional Tools for Xcode 中提供的专有开发工具，遥伴**不捆绑、不镜像、不重新分发**。
- 需要使用时，请你自行从 [Apple 官方渠道](https://developer.apple.com/download/all/) 免费下载并安装（需 Apple Account 与免费 Apple Developer 注册，不需要每年 99 美元的付费会员）。
- 不安装 PacketLogger 时：Apple 遥控器语音不可用；Apple 按键、长按、自定义映射、圆盘触控，以及小米遥控器语音和其他主要功能**均不受影响**。

完整步骤见 [docs/APPLE_VOICE_OPTIONAL_SETUP.md](docs/APPLE_VOICE_OPTIONAL_SETUP.md)。

## 当前状态与已知边界

- 0.10.6 安装修正版已由开发者用户在当前设备上验证可用，公开发布材料正在整理；当前为公开测试版，**不是正式发行版**（仅限当前设备验证，未覆盖全新机器与全部 macOS）。
- 尚未完成 Developer ID 签名与 Apple 公证，本仓库暂不提供安装包下载。
- AI 眼镜属于未来适配方向，目前仅为概念展示，**尚未适配**。
- Apple 遥控器删除后重新配对时，触控与语音恢复稳定性仍在继续验证。

更多文档：

- 测试版安装概览：[docs/BETA_INSTALL.md](docs/BETA_INSTALL.md)
- 已知限制：[docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md)
- 代码托管平台首发说明：[docs/CODE_HOSTING_BETA_RELEASE_NOTES.md](docs/CODE_HOSTING_BETA_RELEASE_NOTES.md)
- 发布检查清单：[docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md)

## 隐私边界

- 空闲待命时不建立普通键盘的全局文本监听；遥控器触发映射时才临时开启协调通道。
- 语音只来自当前绑定遥控器的蓝牙通道，不以 Mac 内建或 USB 麦克风为隐式备用来源。
- 不上传原始蓝牙数据与语音；临时捕获文件在退出和服务恢复时清理。
- 语音识别、文字生成与智能体任务由你选择的输入法、智能体或办公软件完成，其数据处理由对应第三方隐私政策负责。

完整说明见 [PRIVACY.md](PRIVACY.md)。

## 反馈与参与

欢迎在 Issue 中反馈问题或提出建议。提交时请附上：macOS 版本、Mac 芯片、遥控器准确型号、遥伴版本、复现步骤与实际结果；上传日志或截图前，请先删除个人信息、设备地址与语音内容。

首条反馈帖：[你希望遥伴帮你省掉哪一步操作？](https://github.com/cyh211-hub/yovolpen/issues)

## 开源协议

本项目以 [GPL-3.0](LICENSE) 协议开源。第三方归属与来源说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

> 第三方产品名称仅用于说明兼容关系与获取来源，不代表 Apple、小米、豆包、OpenAI 或其他方与本项目存在联名、合作、授权背书或官方认证。遥伴不是小米、豆包或 OpenAI 的官方产品。
