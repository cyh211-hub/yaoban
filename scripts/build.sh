#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
preview_only="${YAOBAN_PREVIEW:-0}"
bundle_id="local.moss.MiRemoteLab"
default_app="$PWD/build/遥伴.app"
if [[ "$preview_only" == "1" ]]; then
    bundle_id="local.moss.YaobanPreview"
    default_app="$PWD/build/遥伴-0.8-预览.app"
fi
app_dir="${YAOBAN_APP_OUTPUT:-$default_app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" .build/module-cache
target_arch="${MI_REMOTE_ARCH:-$(/usr/bin/uname -m)}"
if [[ -z "${MI_REMOTE_ARCH:-}" && "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then target_arch=arm64; fi
case "$target_arch" in arm64|x86_64) ;; *) print -u2 "Unsupported target architecture"; exit 1 ;; esac
# The locally available libopus was compiled for macOS 26. This preview must
# not advertise the previous app's macOS 14 floor until that dependency is rebuilt.
target_os="${YAOBAN_MIN_OS:-26.0}"
opus_prefix="${YAOBAN_OPUS_PREFIX:-$PWD/.build/opus-install}"
[[ -f "$opus_prefix/include/opus/opus.h" && -f "$opus_prefix/lib/libopus.a" ]] || { print -u2 "Set YAOBAN_OPUS_PREFIX to an existing libopus installation."; exit 1; }
/usr/bin/lipo "$opus_prefix/lib/libopus.a" -verify_arch "$target_arch"
xcrun clang -target "${target_arch}-apple-macos${target_os}" -std=c11 -O2 -I Sources/AudioBuffer/include -c Sources/AudioBuffer/AudioRing.c -o .build/AudioRing.o
xcrun swiftc -target "${target_arch}-apple-macos${target_os}" -swift-version 5 -O -module-cache-path "$PWD/.build/module-cache" -I Sources/AudioBuffer/include -o "$app_dir/Contents/MacOS/MiRemoteLab" -Xcc -I -Xcc "$opus_prefix/include/opus" -import-objc-header "$opus_prefix/include/opus/opus.h" Sources/MiRemoteLab/*.swift Sources/AppleVoiceLab/*.swift Sources/AppleVoiceCheck/BoundApple.swift "$opus_prefix/lib/libopus.a" .build/AudioRing.o -framework AppKit -framework CoreBluetooth -framework IOKit -framework IOBluetooth -framework CoreAudio -framework AudioToolbox -framework ServiceManagement
python3 - "$app_dir/Contents/Info.plist" "$preview_only" "$target_os" <<'PY'
import plistlib,sys
info = dict(CFBundleName='遥伴', CFBundleDisplayName='遥伴', CFBundleIdentifier='local.moss.MiRemoteLab', CFBundleExecutable='MiRemoteLab', CFBundlePackageType='APPL', CFBundleIconFile='Yaoban.icns', CFBundleShortVersionString='0.10.8', CFBundleVersion='26', LSMultipleInstancesProhibited=True, LSUIElement=True, LSMinimumSystemVersion=sys.argv[3], NSHighResolutionCapable=True, NSBluetoothAlwaysUsageDescription='连接你选择的已配对遥控器，在启用麦克风并按下语音键时接收声音。', NSBluetoothPeripheralUsageDescription='连接你选择的已配对遥控器读取按键和语音。')
if sys.argv[2] == '1':
    info.update(CFBundleIdentifier='local.moss.YaobanPreview', CFBundleName='遥伴 0.8 预览', CFBundleDisplayName='遥伴 0.8 预览', YaobanPreviewOnly=True, YaobanFirstRunPreview=True)
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
PY
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" scripts/make-app-icon.swift -o .build/make-app-icon
.build/make-app-icon .build/Yaoban.iconset Assets/Brand/BrandMark.png
python3 scripts/pack-app-icon.py .build/Yaoban.iconset build/Yaoban.icns
cp build/Yaoban.icns "$app_dir/Contents/Resources/"
cp Assets/Brand/BrandMark.png "$app_dir/Contents/Resources/"
cp Assets/Devices/Xiaomi2Pro-illustration.png "$app_dir/Contents/Resources/"
# Clean stale manufacturer imagery when rebuilding an existing output directory.
rm -f "$app_dir/Contents/Resources/Xiaomi2Pro-official.png"
cp Assets/Licenses/* LICENSE THIRD_PARTY.md "$app_dir/Contents/Resources/"
cp build/安装遥控器麦克风.pkg build/卸载遥控器麦克风.pkg "$app_dir/Contents/Resources/"
mkdir -p "$app_dir/Contents/Helpers"
xcrun clang -target "${target_arch}-apple-macos${target_os}" -fobjc-arc -O1 -Wall -Wextra -Werror -Wno-deprecated-declarations -DYB_TOUCH_SERVICE Sources/AppleTouchCheck/main.m -framework Foundation -framework IOKit -o "$app_dir/Contents/Helpers/YaobanTouch"
xcrun swiftc -target "${target_arch}-apple-macos${target_os}" -swift-version 5 -O -module-cache-path "$PWD/.build/module-cache" Sources/AppleVoiceControl/main.swift Sources/AppleVoiceCheck/BoundApple.swift Sources/AppleVoiceCheck/ActivationProbe.swift Sources/AppleVoiceLab/AppleVoiceActivationPolicy.swift Sources/MiRemoteLab/AppleRemoteIdentity.swift Sources/MiRemoteLab/RemoteBluetoothDevice.swift -framework IOKit -framework IOBluetooth -o "$app_dir/Contents/Helpers/YaobanVoiceControl"
codesign --force --sign - --identifier "$bundle_id.voice-control" --options runtime "$app_dir/Contents/Helpers/YaobanVoiceControl"
codesign --force --sign - --identifier "$bundle_id.touch" --options runtime "$app_dir/Contents/Helpers/YaobanTouch"
codesign --force --sign - --identifier "$bundle_id" --options runtime "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
