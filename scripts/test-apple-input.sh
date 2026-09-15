#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/MiRemoteLab/AppleButtonInput.swift Sources/MiRemoteLab/AppleHIDConnectionPolicy.swift Sources/MiRemoteLab/RemoteBluetoothDevice.swift Tests/AppleRemote/main.swift -framework IOKit -framework IOBluetooth -o .build/apple-input-tests
.build/apple-input-tests
