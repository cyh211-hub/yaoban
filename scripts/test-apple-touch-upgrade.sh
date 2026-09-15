#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
  Sources/MiRemoteLab/RemoteTouchMotion.swift Tests/AppleTouchUpgrade/main.swift \
  -o .build/apple-touch-upgrade-tests
.build/apple-touch-upgrade-tests
