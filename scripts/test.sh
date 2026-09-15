#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache
xcrun clang -std=c11 -O2 -I Sources/AudioBuffer/include -c Sources/AudioBuffer/AudioRing.c -o .build/AudioRing-test.o
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" -I Sources/AudioBuffer/include Sources/MiRemoteLab/ATVVProtocol.swift Sources/MiRemoteLab/AppleButtonInput.swift Sources/MiRemoteLab/AppleRemoteIdentity.swift Sources/MiRemoteLab/RemoteButtonLayout.swift Sources/MiRemoteLab/RemoteReport.swift Sources/MiRemoteLab/KeyMapping.swift Sources/MiRemoteLab/RemoteActionEngine.swift Sources/MiRemoteLab/MappingProfiles.swift Sources/MiRemoteLab/BuiltInPresets.swift Sources/MiRemoteLab/RemoteSetup.swift Sources/MiRemoteLab/RemoteCatalog.swift Sources/MiRemoteLab/RemoteConnectionPolicy.swift Sources/MiRemoteLab/DeviceLibrary.swift Sources/MiRemoteLab/DevicePresetTransaction.swift Sources/MiRemoteLab/PrivateFiles.swift Sources/MiRemoteLab/DiagnosticsStore.swift Sources/MiRemoteLab/DeviceStatus.swift Sources/MiRemoteLab/RemoteBattery.swift Sources/MiRemoteLab/RemoteSecurity.swift Sources/MiRemoteLab/MappingStore.swift Sources/MiRemoteLab/KeyboardEventChannel.swift Sources/MiRemoteLab/KeyboardEmitter.swift Sources/MiRemoteLab/ShortcutCapture.swift Sources/MiRemoteLab/VoiceProcessing.swift Tests/main.swift .build/AudioRing-test.o -framework AppKit -o .build/protocol-tests
.build/protocol-tests
/usr/bin/python3 - <<'PY'
import audioop, struct, wave
with wave.open('.build/test-fixture.wav','rb') as w:
    assert (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()) == (1,2,16000,16)
    pcm=w.readframes(w.getnframes())
expected,_=audioop.adpcm2lin(bytes.fromhex('123456789abcdef0'),2,None)
assert pcm == expected
print('PASS: WAV format and PCM checked with independent standard-library decoder')
PY
zsh scripts/test-apple-input.sh
