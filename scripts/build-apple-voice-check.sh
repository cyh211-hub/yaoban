#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
opus_prefix="${YAOBAN_TEST_OPUS_PREFIX:-/opt/homebrew/opt/opus}"
voice_os="$(/usr/bin/sw_vers -productVersion)"
voice_os="${voice_os%%.*}.0"
mkdir -p .build/apple-voice-lab/cache
xcrun swiftc -target "arm64-apple-macos${voice_os}" -swift-version 5 -module-cache-path "$PWD/.build/apple-voice-lab/cache" -Xcc -I -Xcc "$opus_prefix/include/opus" -import-objc-header "$opus_prefix/include/opus/opus.h" Sources/AppleVoiceLab/*.swift Sources/AppleVoiceCheck/*.swift Sources/MiRemoteLab/AppleRemoteIdentity.swift Sources/MiRemoteLab/RemoteBluetoothDevice.swift "$opus_prefix/lib/libopus.a" -framework IOKit -framework IOBluetooth -o .build/apple-voice-lab/voice-check
codesign --force --sign - --options runtime --identifier local.moss.YaobanAppleVoiceCheck .build/apple-voice-lab/voice-check
