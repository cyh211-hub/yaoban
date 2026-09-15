#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/MiRemoteLab/RemoteTouchMotion.swift Tests/AppleTouch/main.swift -o .build/apple-touch-tests
.build/apple-touch-tests
