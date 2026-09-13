# Apple 遥控器语音：可选组件安装说明

Apple Siri Remote 的按键、长按、触控板和自定义映射属于遥伴主体功能。只有使用 Apple 遥控器自身的麦克风时，才需要本页组件。

## 为什么需要 PacketLogger

当前语音链路为：

> Siri Remote 蓝牙语音数据 → Apple PacketLogger 捕获原始 HCI 数据 → 遥伴提取并重组语音帧 → Opus 解码 → PCM →“遥控器麦克风”虚拟声卡

遥伴已经实现 PacketLogger 后面的语音帧识别、分片重组、Opus 解码、虚拟声卡和输入路由。当前仍依赖 PacketLogger 取得最前端原始蓝牙数据。

PacketLogger 是 Apple 在 Additional Tools for Xcode 中提供的专有开发工具。遥伴的仓库、安装包、镜像和附件都不会捆绑或重新分发它。

## 获取方式

1. 准备一个 Apple Account。
2. 免费注册 Apple Developer，并阅读、接受 Apple 提供该下载所要求的协议。
3. 从 Apple 官方下载页面获取与当前 Xcode 工具版本匹配的 Additional Tools for Xcode。
4. 从下载内容安装 PacketLogger，并保留在 `/Applications/PacketLogger.app`。
5. 回到遥伴的语音设置，启用 Apple 遥控器语音并按界面提示完成组件检查。

官方入口：[Apple Developer Downloads](https://developer.apple.com/download/all/)；[Xcode Resources](https://developer.apple.com/xcode/resources/)。该下载不要求每年 99 美元的 Apple Developer Program 付费会员，但需要登录、免费开发者注册并接受对应协议。页面内容和工具版本可能由 Apple 调整。

## 使用时会发生什么

- Apple 语音准备和收音期间，系统级蓝牙诊断入口可能经过其他蓝牙设备流量。
- 遥伴只把当前绑定 Apple 地址的有效语音帧送入解码。
- 临时原始捕获文件放在 root 私有目录，正常或异常结束时清理；服务启动时还会处理本组件遗留的临时文件和诊断恢复记录。
- 语音会话有时间上限，停用设备、断开、退出或异常会停止采集。
- 遥伴不会把 PacketLogger、原始蓝牙捕获或语音上传到网络。
- 目标输入法或智能体可能按自己的规则处理已经送入虚拟麦克风的声音，需另行查看其隐私政策。

## 不安装时

不安装 PacketLogger 不会影响 Apple 按键、长按、自定义映射和圆盘触控，也不会影响小米遥控器语音。遥伴应显示 Apple 语音组件未就绪，而不是阻止整个应用安装。

## 后续方向

项目计划开发自有蓝牙采集模块，最终去掉 PacketLogger 和 Apple Developer 登录依赖。该方向不作为测试版主体功能发布的阻塞条件。
