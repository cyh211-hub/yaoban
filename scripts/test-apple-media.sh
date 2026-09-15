#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
 Sources/MiRemoteLab/AppleButtonInput.swift Sources/MiRemoteLab/AppleRemoteIdentity.swift \
 Sources/MiRemoteLab/RemoteButtonLayout.swift Sources/MiRemoteLab/RemoteReport.swift \
 Sources/MiRemoteLab/DeviceStatus.swift Sources/MiRemoteLab/RemoteSecurity.swift Sources/MiRemoteLab/PrivateFiles.swift \
 Sources/MiRemoteLab/KeyMapping.swift Sources/MiRemoteLab/AppleMediaPolicy.swift \
 Tests/AppleMedia/main.swift -o .build/apple-media-tests
.build/apple-media-tests
