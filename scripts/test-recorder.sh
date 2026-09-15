#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/MiRemoteLab/ShortcutRecorder.swift Sources/MiRemoteLab/ShortcutCapture.swift Sources/MiRemoteLab/KeyboardSignalProbe.swift Sources/MiRemoteLab/KeyMapping.swift Sources/MiRemoteLab/RemoteReport.swift Sources/MiRemoteLab/RemoteButtonLayout.swift Sources/MiRemoteLab/AppleButtonInput.swift Sources/MiRemoteLab/DeviceStatus.swift Sources/MiRemoteLab/PrivateFiles.swift Tests/RecorderLifecycle/main.swift -framework AppKit -framework IOKit -o .build/recorder-lifecycle-tests
.build/recorder-lifecycle-tests
