#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_dir="$PWD/build/遥伴-苹果适配检查.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" .build/module-cache
xcrun swiftc -target arm64-apple-macos14.0 -swift-version 5 -O -module-cache-path "$PWD/.build/module-cache" Sources/MiRemoteLab/AppleButtonInput.swift Sources/MiRemoteLab/PrivateFiles.swift Sources/AppleRemoteCheck/main.swift -framework AppKit -framework IOKit -o "$app_dir/Contents/MacOS/YaobanAppleCheck"
python3 - "$app_dir" <<'PY'
import pathlib,plistlib,shutil,sys
p=pathlib.Path(sys.argv[1])
info=dict(CFBundleName='遥伴 苹果适配检查',CFBundleDisplayName='遥伴 苹果适配检查',CFBundleIdentifier='local.moss.YaobanAppleCheck',CFBundleExecutable='YaobanAppleCheck',CFBundlePackageType='APPL',CFBundleShortVersionString='0.1.0',CFBundleVersion='1',LSMinimumSystemVersion='14.0',LSMultipleInstancesProhibited=True,NSHighResolutionCapable=True)
if pathlib.Path('build/Yaoban.icns').exists():
 shutil.copy2('build/Yaoban.icns',p/'Contents/Resources/Yaoban.icns');info['CFBundleIconFile']='Yaoban.icns'
with (p/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
codesign --force --sign - --options runtime "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
