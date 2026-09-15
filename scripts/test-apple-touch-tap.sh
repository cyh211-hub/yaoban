#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
  Sources/MiRemoteLab/AppleButtonInput.swift Sources/MiRemoteLab/DeviceStatus.swift \
  Sources/MiRemoteLab/RemoteButtonLayout.swift Sources/MiRemoteLab/RemoteReport.swift \
  Sources/MiRemoteLab/KeyMapping.swift Sources/MiRemoteLab/RemoteTouchMotion.swift \
  Sources/MiRemoteLab/RemoteTouchTap.swift Tests/AppleTouchTap/main.swift \
  -o .build/apple-touch-tap-tests
.build/apple-touch-tap-tests
