# 从源码构建 0.10.8

此源码包与公开候选来自同一份源文件。构建会生成本地文件，不会安装或更改系统权限。编译器和系统 SDK 差异可能使二进制哈希不同，不承诺逐字节可重复构建。

## 环境

Apple Silicon Mac，macOS 26；Apple Command Line Tools 或 Xcode（需有 xcrun、clang、Swift、make）；Python 3.9 或以上。macOS 自带 pkgbuild、codesign、tar。系统安装脚本使用 `/usr/bin/python3`，未提供该解释器的系统需要先安装 Apple Command Line Tools。

发布候选按 arm64 / macOS 26 构建，不宣称支持 Intel 或较早 macOS。Opus 1.6.1 原始源码归档已包含，不依赖某个开发者的 Homebrew 安装。

## 顺序

在解压后的源码根目录运行：

```sh
zsh scripts/build-opus.sh
python3 scripts/build-audio-driver.py
python3 scripts/package-audio-driver.py
MI_REMOTE_ARCH=arm64 YAOBAN_OPUS_PREFIX="$PWD/.build/opus-install" YAOBAN_APP_OUTPUT="$PWD/.build/v0108/遥伴.app" zsh scripts/build.sh
python3 scripts/package-v0108.py
python3 scripts/verify-v0108-package.py
```

结果为 `build/遥伴-0.10.8-公开测试版.pkg` 和配套回退包。源码中的内部 Yaoban / MiRemoteLab 名称为兼容既有用户设置而保留，不要进行全局改名。

临时签名仅用于本地构建验证，并非 Developer ID 签名或 Apple 公证。不要编辑已签名 app 内的文件；修改源文件后重新构建。

回退包不是卸载器，只用于安装本版本时成功建立了备份的同一台机器。无需把回退包当成普通用户首次安装步骤。
